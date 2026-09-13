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
    /// Local size 8×8 matches the `(w + 7) / 8` dispatch in
    /// `OGLShaderNode.update` exactly.
    static func compute(functions: String, body: String) -> String {
        if body.trimmingCharactersInWhitespace().hasPrefix("#version") {
            return body
        }
        return """
        #version 450

        layout(local_size_x = 8, local_size_y = 8) in;
        layout(binding = 0, rgba8) uniform writeonly image2D uOutput;
        layout(binding = 1) uniform Uniforms {
            vec4 timeInfo;    // x: time, y: delta, z: frame
            vec4 res;         // xy: resolution
            vec4 mouseInfo;   // xy: position, zw: position while pressed
        } u;

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

    init(engine: NucleantRenderEngine, imageView: VkImageView, source: String) throws {
        self.device = engine.device
        self.uniforms = engine.createBuffer(
            size: MemoryLayout<ShaderUniforms>.stride,
            usage: VkBufferUsageFlags(VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT.rawValue)
        )

        guard let spirv = VKShaderCompiler.shared.tryCompileCompute(source) else {
            uniforms.destroy(device: device)
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
            try createDescriptorSet(imageView: imageView)
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

    /// Idempotent. The caller drains the GPU first — an in-flight command
    /// buffer may still reference these objects.
    func destroy() {
        if let pipeline { vkDestroyPipeline(device, pipeline, nil) }
        if let pipelineLayout { vkDestroyPipelineLayout(device, pipelineLayout, nil) }
        if let shaderModule { vkDestroyShaderModule(device, shaderModule, nil) }
        if let setLayout { vkDestroyDescriptorSetLayout(device, setLayout, nil) }
        if let descriptorPool { vkDestroyDescriptorPool(device, descriptorPool, nil) }
        uniforms.destroy(device: device)
        pipeline = nil
        pipelineLayout = nil
        shaderModule = nil
        setLayout = nil
        descriptorPool = nil
        descriptorSet = nil
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

        let bindings = [output, uniform]
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

    private func createDescriptorSet(imageView: VkImageView) throws {
        let sizes = [
            VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, descriptorCount: 1),
            VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, descriptorCount: 1),
        ]
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

        withUnsafePointer(to: &imageInfo) { imagePtr in
            withUnsafePointer(to: &bufferInfo) { bufferPtr in
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
                vkUpdateDescriptorSets(device, 2, &writes, 0, nil)
            }
        }
    }
}
