//
//  ShaderPipeline.swift
//  NucleantSwiftUI
//
//  The GPU half of a `Shader` view: a storage image the compute shader writes,
//  the compute pipeline itself, and a uniform buffer carrying time/resolution/
//  mouse. The engine's `OGLShaderNode` already knows how to dispatch a compute
//  pipeline into its own image and barrier the result for the composite pass —
//  it simply had no factory, so this is that factory.
//
//  Descriptor layout matches `VulkanCore.TexGenComputePipeline`:
//    binding 0 — storage image (the shader's output)
//    binding 1 — uniform buffer (`ShaderUniforms`)
//    binding 2 — sampled image (the view's own pixels), for a `.shader` effect
//    binding 3 — storage buffer (`ShaderArgument`s), when the shader has any
//  A dedicated one-set pool per shader, for the reason the engine gives every
//  composite node its own: MoltenVK packing several same-layout sets into one
//  pool misaligns Metal argument-buffer offsets.
//

import CVulkan
import VulkanCore
import NucleantVulkan
import NucleantShader

/// What every shader gets for free, matching the `Uniforms` block the wrapper
/// in `ShaderSource` declares. `std140` puts a `vec2` on an 8-byte boundary,
/// which the explicit padding here honours.
struct ShaderUniforms {
    // vec4 timeInfo — x: seconds, y: frame delta, z: frame number
    var time: Float = 0
    var timeDelta: Float = 0
    var frame: Float = 0
    var _pad0: Float = 0
    // vec4 resolution — xy only
    var resolutionX: Float = 0
    var resolutionY: Float = 0
    var _pad1: Float = 0
    var _pad2: Float = 0
    // vec4 mouse — xy: position, zw: position while pressed (ShaderToy's shape)
    var mouseX: Float = 0
    var mouseY: Float = 0
    var mouseClickX: Float = 0
    var mouseClickY: Float = 0
}

enum ShaderError: Error {
    case compileFailed(String)
    case vulkan(String)
}

/// Wraps user GLSL into the compute contract above.
enum ShaderSource {

    /// A body written in fragment-shader terms — `uv`, `time`, `resolution`
    /// and `mouse` are in scope and it assigns `fragColor` — becomes a
    /// complete compute shader. Source that already starts with `#version` is
    /// passed through untouched, so a full compute shader is an escape hatch.
    ///
    /// With `samplesContent`, the wrapper also declares the view's own pixels
    /// as `uContent` (and ShaderToy's `iChannel0`), plus `layer(uv)` to read
    /// them — what a `.shader(_:)` effect is given.
    ///
    /// Local size 8×8 matches the `(w + 7) / 8` dispatch in
    /// `OGLShaderNode.update` exactly.
    static func compute(
        functions: String,
        body: String,
        samplesContent: Bool = false,
        arguments: ShaderArguments = .none
    ) -> String {
        if body.trimmingCharactersInWhitespace().hasPrefix("#version") {
            return body
        }
        let (argumentDeclarations, argumentLoads) = argumentSource(arguments)
        let content = samplesContent ? """
        // The view this effect is applied to, rendered into its own texture
        // and stored y-up like everything else in shader space — so
        // `layer(uv)` is the view's pixel under the current one, and an
        // unmodified ShaderToy `texture(iChannel0, uv)` reads it upright.
        layout(binding = 2) uniform sampler2D uContent;
        #define iChannel0 uContent
        vec3 iChannelResolution[4];

        vec4 layer(vec2 p) { return texture(uContent, p); }
        """ : ""
        return """
        #version 450

        layout(local_size_x = 8, local_size_y = 8) in;
        layout(binding = 0, rgba8) uniform writeonly image2D uOutput;
        layout(binding = 1) uniform Uniforms {
            vec4 timeInfo;    // x: time, y: delta, z: frame
            vec4 res;         // xy: resolution
            vec4 mouseInfo;   // xy: position, zw: position while pressed
        } u;
        \(content)
        \(argumentDeclarations)

        // Constants every ShaderToy-style body reaches for, so each one does
        // not have to redeclare them.
        const float PI      = 3.14159265359;
        const float TAU     = 6.28318530718;
        const float HALF_PI = 1.57079632679;

        // File-scope, not locals in `main`: a helper in `functions` has to be
        // able to read them, and ported shaders routinely do — CyberFuji's
        // `sun()` and `grid()` both use `time` without taking it as a
        // parameter. Assigned once at the top of `main`, which is the only
        // caller, so every helper sees the current frame's values.
        float time;
        vec2  resolution;
        vec2  mouse;

        // The ShaderToy uniform set, in ShaderToy's own types — `iResolution`
        // is a vec3 and `iMouse` a vec4 there, and shaders written against it
        // rely on that (`iMouse.z > 0.0` to test for a press, `iResolution.xy`
        // to divide by). Declaring them with the right shapes is most of what
        // makes an unmodified `mainImage` compile.
        float iTime;
        float iTimeDelta;
        int   iFrame;
        vec3  iResolution;
        vec4  iMouse;

        \(functions)

        void main() {
            ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
            ivec2 size  = imageSize(uOutput);
            if (pixel.x >= size.x || pixel.y >= size.y) { return; }

            time        = u.timeInfo.x;
            resolution  = vec2(size);
            // Pointer position is delivered top-down (the view system's
            // convention) and flipped here with everything else.
            mouse       = vec2(u.mouseInfo.x, resolution.y - u.mouseInfo.y);
            iTime       = time;
            iTimeDelta  = u.timeInfo.y;
            iFrame      = int(u.timeInfo.z);
            iResolution = vec3(resolution, 1.0);
            iMouse      = vec4(mouse, u.mouseInfo.z, resolution.y - u.mouseInfo.w);
        \(samplesContent ? "    iChannelResolution[0] = iResolution;" : "")
        \(argumentLoads)

            // Shader space is y-up, with (0, 0) at the bottom-left — the
            // convention every ShaderToy shader is written against. The image
            // itself is stored top-down, so only the coordinates handed to the
            // body are flipped; `pixel`, the store location, is untouched.
            //
            // Without this every ported shader came out vertically mirrored,
            // which is subtle in a symmetric one (Plasma) and obvious in a
            // shader with a horizon: CyberFuji's `if (p.y < -0.2)` draws its
            // neon floor grid, and it was appearing along the top.
            vec2 fragCoord = vec2(float(pixel.x) + 0.5, float(size.y - pixel.y) - 0.5);
            vec2 uv        = fragCoord / resolution;
            vec4 fragColor = vec4(0.0, 0.0, 0.0, 1.0);

            // The body is its own scope, so a port may redeclare `uv` or
            // `fragCoord` — many do — and shadow these rather than collide.
            {
        \(body)
            }

            imageStore(uOutput, pixel, fragColor);
        }
        """
    }
}

extension ShaderSource {
    /// The GLSL behind `ShaderArgument`s: one storage buffer of floats, a
    /// header of (offset, count) pairs at its front, and a named variable —
    /// or, for an array, an accessor function and a count — per argument.
    /// Values are loaded at the top of `main` so helpers in `functions` can
    /// read the scalars the way they read `time`.
    ///
    /// The declarations depend only on names and kinds, never on values or
    /// lengths, so changing an array's contents or length never recompiles.
    static func argumentSource(_ arguments: ShaderArguments) -> (declarations: String, loads: String) {
        guard !arguments.isEmpty else { return ("", "") }
        var declarations = """
        layout(std430, binding = 3) readonly buffer ShaderArgs { float data[]; } uArgs;
        #define ARG_OFFSET(i) int(uArgs.data[(i) * 2])
        #define ARG_COUNT(i)  int(uArgs.data[(i) * 2 + 1])

        """
        var loads = ""
        for (index, declaration) in arguments.declarations.enumerated() {
            let name = declaration.name
            let at = "ARG_OFFSET(\(index))"
            switch declaration.type {
            case "array":
                declarations += """
                int \(name)Count;
                float \(name)(int i) {
                    int n = ARG_COUNT(\(index));
                    return n > 0 ? uArgs.data[\(at) + clamp(i, 0, n - 1)] : 0.0;
                }

                """
                loads += "    \(name)Count = ARG_COUNT(\(index));\n"
            case "float":
                declarations += "float \(name);\n"
                loads += "    \(name) = uArgs.data[\(at)];\n"
            case "vec2":
                declarations += "vec2 \(name);\n"
                loads += "    \(name) = vec2(uArgs.data[\(at)], uArgs.data[\(at) + 1]);\n"
            case "vec3":
                declarations += "vec3 \(name);\n"
                loads += "    \(name) = vec3(uArgs.data[\(at)], uArgs.data[\(at) + 1], uArgs.data[\(at) + 2]);\n"
            default:
                declarations += "vec4 \(name);\n"
                loads += "    \(name) = vec4(uArgs.data[\(at)], uArgs.data[\(at) + 1], "
                    + "uArgs.data[\(at) + 2], uArgs.data[\(at) + 3]);\n"
            }
        }
        return (declarations, loads)
    }
}

private extension String {
    func trimmingCharactersInWhitespace() -> String {
        var result = Substring(self)
        while let first = result.first, first.isWhitespace || first.isNewline {
            result = result.dropFirst()
        }
        return String(result)
    }
}

/// Everything Vulkan behind one `Shader` view.
@MainActor
final class ShaderPipeline {

    private let device: VkDevice

    private(set) var pipeline: VkPipeline?
    private(set) var pipelineLayout: VkPipelineLayout?
    private(set) var descriptorSet: VkDescriptorSet?

    private var setLayout: VkDescriptorSetLayout?
    private var shaderModule: VkShaderModule?
    private var descriptorPool: VkDescriptorPool?
    private var uniforms: BufferAndMemory
    /// Only with an `input`: how the shader samples the view's pixels.
    private var sampler: VkSampler?
    private let hasInput: Bool
    /// The `ShaderArgument` storage buffer, when the shader declares any.
    /// Sized once, with headroom; a list that outgrows it rebuilds the slot.
    private var arguments: BufferAndMemory?
    /// Floats the argument buffer can hold; 0 when there is none.
    let argumentCapacity: Int

    /// `input` is the image the shader may sample at binding 2 — the canvas a
    /// `.shader` effect's view is drawn into. Left in `SHADER_READ_ONLY_OPTIMAL`
    /// by its own node's update, which runs before this pipeline's dispatch.
    ///
    /// `argumentCapacity` is how many floats of `ShaderArgument` data to make
    /// room for — 0 for a shader without arguments, which then has no
    /// binding 3 at all.
    init(
        engine: NucleantRenderEngine,
        imageView: VkImageView,
        input: VkImageView? = nil,
        source: String,
        argumentCapacity: Int = 0
    ) throws {
        self.device = engine.device
        self.hasInput = input != nil
        self.argumentCapacity = argumentCapacity
        self.uniforms = engine.createBuffer(
            size: MemoryLayout<ShaderUniforms>.stride,
            usage: VkBufferUsageFlags(VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT.rawValue)
        )
        if argumentCapacity > 0 {
            arguments = engine.createBuffer(
                size: argumentCapacity * MemoryLayout<Float>.stride,
                usage: VkBufferUsageFlags(VK_BUFFER_USAGE_STORAGE_BUFFER_BIT.rawValue)
            )
        }

        guard let spirv = VKShaderCompiler.shared.tryCompileCompute(source) else {
            uniforms.destroy(device: device)
            arguments?.destroy(device: device)
            // The real GLSL diagnostics, with the line numbers of the *wrapped*
            // shader — which is what someone pasting a ShaderToy source needs
            // to see rather than a bare "failed".
            throw ShaderError.compileFailed(
                VKShaderCompiler.shared.lastErrorMessage ?? "shaderc rejected the compute shader"
            )
        }

        do {
            try createSetLayout()
            try createPipelineLayout()
            shaderModule = try ShaderModuleLoader.load(device: device, spirv: spirv)
            try createPipeline()
            if input != nil { try createSampler() }
            try createDescriptorSet(imageView: imageView, input: input)
        } catch {
            destroy()
            throw error
        }
    }

    /// Per-frame uniform write. Host-visible and coherent, so this is a plain
    /// memcpy with no barrier — the value the next dispatch reads.
    func update(_ values: ShaderUniforms) {
        var copy = values
        uniforms.update(
            device: device,
            data: &copy,
            bytes: MemoryLayout<ShaderUniforms>.stride
        )
    }

    /// The argument buffer, whole. Same contract as `update`: host-coherent,
    /// read by the next dispatch. A list longer than the capacity is a
    /// caller error — the registry rebuilds the slot before it gets here.
    func updateArguments(_ packed: [Float]) {
        guard let arguments, !packed.isEmpty else { return }
        let count = min(packed.count, argumentCapacity)
        packed.withUnsafeBufferPointer { buffer in
            arguments.update(
                device: device,
                data: UnsafeRawPointer(buffer.baseAddress!),
                bytes: count * MemoryLayout<Float>.stride
            )
        }
    }

    /// Idempotent. The caller drains the GPU first — an in-flight command
    /// buffer may still reference these objects.
    func destroy() {
        if let pipeline { vkDestroyPipeline(device, pipeline, nil) }
        if let pipelineLayout { vkDestroyPipelineLayout(device, pipelineLayout, nil) }
        if let shaderModule { vkDestroyShaderModule(device, shaderModule, nil) }
        if let setLayout { vkDestroyDescriptorSetLayout(device, setLayout, nil) }
        if let descriptorPool { vkDestroyDescriptorPool(device, descriptorPool, nil) }
        if let sampler { vkDestroySampler(device, sampler, nil) }
        uniforms.destroy(device: device)
        arguments?.destroy(device: device)
        arguments = nil
        pipeline = nil
        pipelineLayout = nil
        shaderModule = nil
        setLayout = nil
        descriptorPool = nil
        descriptorSet = nil
        sampler = nil
        uniforms = BufferAndMemory()
    }

    // MARK: - Creation

    private func createSetLayout() throws {
        var output = VkDescriptorSetLayoutBinding()
        output.binding = 0
        output.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE
        output.descriptorCount = 1
        output.stageFlags = VkShaderStageFlags(VK_SHADER_STAGE_COMPUTE_BIT.rawValue)

        var uniform = VkDescriptorSetLayoutBinding()
        uniform.binding = 1
        uniform.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
        uniform.descriptorCount = 1
        uniform.stageFlags = VkShaderStageFlags(VK_SHADER_STAGE_COMPUTE_BIT.rawValue)

        var bindings = [output, uniform]
        if hasInput {
            var input = VkDescriptorSetLayoutBinding()
            input.binding = 2
            input.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
            input.descriptorCount = 1
            input.stageFlags = VkShaderStageFlags(VK_SHADER_STAGE_COMPUTE_BIT.rawValue)
            bindings.append(input)
        }
        if arguments != nil {
            var storage = VkDescriptorSetLayoutBinding()
            storage.binding = 3
            storage.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
            storage.descriptorCount = 1
            storage.stageFlags = VkShaderStageFlags(VK_SHADER_STAGE_COMPUTE_BIT.rawValue)
            bindings.append(storage)
        }
        let result = bindings.withUnsafeBufferPointer { buffer -> VkResult in
            var info = VkDescriptorSetLayoutCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
            info.bindingCount = UInt32(buffer.count)
            info.pBindings = buffer.baseAddress
            return vkCreateDescriptorSetLayout(device, &info, nil, &setLayout)
        }
        guard result == VK_SUCCESS else { throw ShaderError.vulkan("descriptor set layout") }
    }

    private func createPipelineLayout() throws {
        let result = withUnsafePointer(to: setLayout) { layoutPtr -> VkResult in
            var info = VkPipelineLayoutCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
            info.setLayoutCount = 1
            info.pSetLayouts = layoutPtr
            return vkCreatePipelineLayout(device, &info, nil, &pipelineLayout)
        }
        guard result == VK_SUCCESS else { throw ShaderError.vulkan("pipeline layout") }
    }

    private func createPipeline() throws {
        let result = "main".withCString { entry -> VkResult in
            var stage = VkPipelineShaderStageCreateInfo()
            stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
            stage.stage = VK_SHADER_STAGE_COMPUTE_BIT
            stage.module = shaderModule
            stage.pName = entry

            var info = VkComputePipelineCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO
            info.stage = stage
            info.layout = pipelineLayout
            info.basePipelineIndex = -1
            return vkCreateComputePipelines(device, nil, 1, &info, nil, &pipeline)
        }
        guard result == VK_SUCCESS else { throw ShaderError.vulkan("compute pipeline") }
    }

    /// Linear, clamped: a distortion that samples past the edge gets the edge
    /// pixel rather than a wrapped copy of the far side.
    private func createSampler() throws {
        var info = VkSamplerCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
        info.magFilter = VK_FILTER_LINEAR
        info.minFilter = VK_FILTER_LINEAR
        info.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
        info.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
        info.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
        guard vkCreateSampler(device, &info, nil, &sampler) == VK_SUCCESS else {
            throw ShaderError.vulkan("sampler")
        }
    }

    private func createDescriptorSet(imageView: VkImageView, input: VkImageView?) throws {
        var sizes = [
            VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, descriptorCount: 1),
            VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, descriptorCount: 1),
        ]
        if input != nil {
            sizes.append(VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, descriptorCount: 1))
        }
        if arguments != nil {
            sizes.append(VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, descriptorCount: 1))
        }
        let poolResult = sizes.withUnsafeBufferPointer { buffer -> VkResult in
            var info = VkDescriptorPoolCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
            info.maxSets = 1
            info.poolSizeCount = UInt32(buffer.count)
            info.pPoolSizes = buffer.baseAddress
            return vkCreateDescriptorPool(device, &info, nil, &descriptorPool)
        }
        guard poolResult == VK_SUCCESS else { throw ShaderError.vulkan("descriptor pool") }

        let allocResult = withUnsafePointer(to: setLayout) { layoutPtr -> VkResult in
            var info = VkDescriptorSetAllocateInfo()
            info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
            info.descriptorPool = descriptorPool
            info.descriptorSetCount = 1
            info.pSetLayouts = layoutPtr
            return vkAllocateDescriptorSets(device, &info, &descriptorSet)
        }
        guard allocResult == VK_SUCCESS else { throw ShaderError.vulkan("descriptor set") }

        // GENERAL is where `OGLShaderNode.update`'s pre-dispatch barrier puts
        // the image, and what a storage binding requires.
        var imageInfo = VkDescriptorImageInfo()
        imageInfo.imageView = imageView
        imageInfo.imageLayout = VK_IMAGE_LAYOUT_GENERAL

        var bufferInfo = VkDescriptorBufferInfo()
        bufferInfo.buffer = uniforms.buffer
        bufferInfo.offset = 0
        bufferInfo.range = VkDeviceSize(MemoryLayout<ShaderUniforms>.stride)

        // The view's canvas, as its own node leaves it after drawing.
        var inputInfo = VkDescriptorImageInfo()
        inputInfo.sampler = sampler
        inputInfo.imageView = input
        inputInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL

        var argumentInfo = VkDescriptorBufferInfo()
        argumentInfo.buffer = arguments?.buffer
        argumentInfo.offset = 0
        argumentInfo.range = VkDeviceSize(VK_WHOLE_SIZE)

        withUnsafePointer(to: &imageInfo) { imagePtr in
            withUnsafePointer(to: &bufferInfo) { bufferPtr in
                withUnsafePointer(to: &inputInfo) { inputPtr in
                withUnsafePointer(to: &argumentInfo) { argumentPtr in
                    var writeImage = VkWriteDescriptorSet()
                    writeImage.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
                    writeImage.dstSet = descriptorSet
                    writeImage.dstBinding = 0
                    writeImage.descriptorCount = 1
                    writeImage.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE
                    writeImage.pImageInfo = imagePtr

                    var writeUniform = VkWriteDescriptorSet()
                    writeUniform.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
                    writeUniform.dstSet = descriptorSet
                    writeUniform.dstBinding = 1
                    writeUniform.descriptorCount = 1
                    writeUniform.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
                    writeUniform.pBufferInfo = bufferPtr

                    var writes = [writeImage, writeUniform]
                    if input != nil {
                        var writeInput = VkWriteDescriptorSet()
                        writeInput.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
                        writeInput.dstSet = descriptorSet
                        writeInput.dstBinding = 2
                        writeInput.descriptorCount = 1
                        writeInput.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
                        writeInput.pImageInfo = inputPtr
                        writes.append(writeInput)
                    }
                    if arguments != nil {
                        var writeArguments = VkWriteDescriptorSet()
                        writeArguments.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
                        writeArguments.dstSet = descriptorSet
                        writeArguments.dstBinding = 3
                        writeArguments.descriptorCount = 1
                        writeArguments.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
                        writeArguments.pBufferInfo = argumentPtr
                        writes.append(writeArguments)
                    }
                    vkUpdateDescriptorSets(device, UInt32(writes.count), &writes, 0, nil)
                }
                }
            }
        }
    }
}
