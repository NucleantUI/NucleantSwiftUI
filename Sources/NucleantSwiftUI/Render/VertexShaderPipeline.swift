//
//  VertexShaderPipeline.swift
//  NucleantSwiftUI
//
//  The GPU half of a `VertexShader` view: a colour-attachment image the
//  pipeline draws into, the graphics pipeline itself, and the uniform and
//  argument buffers — the same descriptor set as `ShaderPipeline` minus what
//  a compute stage needs and a render pass in its place:
//    binding 1 — uniform buffer (`ShaderUniforms`), both stages
//    binding 3 — storage buffer (`ShaderArgument`s), both stages, when any
//  Binding 0 (the storage image) and 2 (the sampled content) do not exist
//  here: the output is the attachment, and there is no `.shader` effect form.
//  Same one-set pool per shader, for the MoltenVK reason `ShaderPipeline`
//  gives.
//

import CVulkan
import VulkanCore
import NucleantVulkan
import NucleantShader
import PyShader

/// What a `VertexShaderFunction` becomes on its way to the pipeline: two GLSL
/// stages for shaderc, or one PyShader module with an entry point per stage.
enum GraphicsShaderCode {
    case glsl(vertex: String, fragment: String)
    case spirv([UInt32], vertexEntryPoint: String, fragmentEntryPoint: String)

    static func graphics(_ function: VertexShaderFunction, arguments: ShaderArguments) throws -> GraphicsShaderCode {
        switch function.language {
        case .glsl:
            let (vertex, fragment) = ShaderSource.graphics(
                functions: function.functions,
                varyings: function.varyings,
                vertex: function.vertex,
                fragment: function.fragment,
                arguments: arguments
            )
            return .glsl(vertex: vertex, fragment: fragment)
        case .pyshader:
            let interface = GraphicsInterface.nucleantSwiftUI(
                arguments: try ShaderArgumentKind.kinds(of: arguments)
            )
            do {
                let compiled = try PyShader.compile(function.vertex, target: .graphics(interface))
                return .spirv(compiled.spirv, vertexEntryPoint: compiled.vertexEntryPoint!, fragmentEntryPoint: compiled.entryPoint)
            } catch let error as PyShaderError {
                throw ShaderError.compileFailed("PyShader: \(error)")
            }
        }
    }
}

extension ShaderSource {

    /// The two stages of a `VertexShaderFunction`, each wrapped into a complete
    /// GLSL 450 shader. Both see the uniforms, the constants and the
    /// arguments; `varyings` is declared as `out`s in one and matching `in`s
    /// in the other, at consecutive locations.
    ///
    /// The vertex body writes `gl_Position` in y-up clip space, as in OpenGL;
    /// the wrapper flips it into Vulkan's, so a quad placed at the top of
    /// shader space lands at the top of the view — matching what `uv` and
    /// `fragCoord` in the fragment stage, and in every compute `Shader`, mean.
    static func graphics(
        functions: String,
        varyings: String,
        vertex: String,
        fragment: String,
        arguments: ShaderArguments
    ) -> (vertex: String, fragment: String) {
        let (argumentDeclarations, argumentLoads) = argumentSource(arguments)
        let outs = varyingDeclarations(varyings, direction: "out")
        let ins = varyingDeclarations(varyings, direction: "in")
        let common = """
        #version 450

        layout(binding = 1) uniform Uniforms {
            vec4 timeInfo;    // x: time, y: delta, z: frame
            vec4 res;         // xy: resolution
            vec4 mouseInfo;   // xy: position, zw: position while pressed
        } u;
        \(argumentDeclarations)

        const float PI      = 3.14159265359;
        const float TAU     = 6.28318530718;
        const float HALF_PI = 1.57079632679;

        float time;
        float timeDelta;
        int   frame;
        vec2  resolution;
        vec2  mouse;

        \(functions)

        void loadUniforms() {
            time       = u.timeInfo.x;
            timeDelta  = u.timeInfo.y;
            frame      = int(u.timeInfo.z);
            resolution = u.res.xy;
            mouse      = vec2(u.mouseInfo.x, resolution.y - u.mouseInfo.y);
        \(argumentLoads)
        }
        """
        let vertexSource = """
        \(common)
        \(outs)

        void main() {
            loadUniforms();
            {
        \(vertex)
            }
            // Shader space is y-up; Vulkan's clip space is y-down.
            gl_Position.y = -gl_Position.y;
        }
        """
        let fragmentSource = """
        \(common)
        \(ins)
        layout(location = 0) out vec4 fragColor;

        void main() {
            loadUniforms();
            // gl_FragCoord is y-down with the pixel centre at +0.5; shader
            // space is y-up, so y is flipped and the centre offset survives.
            vec2 fragCoord = vec2(gl_FragCoord.x, resolution.y - gl_FragCoord.y);
            vec2 uv        = fragCoord / resolution;
            fragColor      = vec4(0.0);
            {
        \(fragment)
            }
        }
        """
        return (vertexSource, fragmentSource)
    }

    /// `"vec2 uv; float seed;"` → one `layout(location = i) out vec2 uv;` per
    /// pair. Integer and boolean types get `flat`, as a fragment input of
    /// those types must be.
    static func varyingDeclarations(_ varyings: String, direction: String) -> String {
        var lines: [String] = []
        for (location, declaration) in varyings.split(separator: ";").enumerated() {
            let words = declaration.split(whereSeparator: { $0.isWhitespace })
            guard words.count == 2 else { continue }
            let type = words[0], name = words[1]
            let flat = type.hasPrefix("int") || type.hasPrefix("uint") || type.hasPrefix("ivec")
                || type.hasPrefix("uvec") || type.hasPrefix("bool") || type.hasPrefix("bvec")
            lines.append("layout(location = \(location)) \(flat ? "flat " : "")\(direction) \(type) \(name);")
        }
        return lines.joined(separator: "\n")
    }
}

/// Everything Vulkan behind one `VertexShader` view.
@MainActor
final class VertexShaderPipeline {

    private let device: VkDevice

    private(set) var pipeline: VkPipeline?
    private(set) var pipelineLayout: VkPipelineLayout?
    private(set) var descriptorSet: VkDescriptorSet?

    private var setLayout: VkDescriptorSetLayout?
    private var descriptorPool: VkDescriptorPool?
    private var uniforms: BufferAndMemory
    /// The `ShaderArgument` storage buffer, when the shader declares any.
    private var arguments: BufferAndMemory?
    /// Floats the argument buffer can hold; 0 when there is none.
    let argumentCapacity: Int

    init(
        engine: NucleantRenderEngine,
        renderPass: VkRenderPass,
        source: GraphicsShaderCode,
        argumentCapacity: Int = 0
    ) throws {
        self.device = engine.device
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

        let vertex: (spirv: [UInt32], entryPoint: String)
        let fragment: (spirv: [UInt32], entryPoint: String)
        switch source {
        case .spirv(let words, let vertexEntryPoint, let fragmentEntryPoint):
            vertex = (words, vertexEntryPoint)
            fragment = (words, fragmentEntryPoint)
        case .glsl(let vertexGLSL, let fragmentGLSL):
            let compiler = VKShaderCompiler.shared
            guard let vertexWords = compiler.compile(source: vertexGLSL, stage: .vertex, filename: "vertex.glsl") else {
                destroy()
                throw ShaderError.compileFailed(compiler.lastErrorMessage ?? "shaderc rejected the vertex shader")
            }
            guard let fragmentWords = compiler.compile(source: fragmentGLSL, stage: .fragment, filename: "fragment.glsl") else {
                destroy()
                throw ShaderError.compileFailed(compiler.lastErrorMessage ?? "shaderc rejected the fragment shader")
            }
            vertex = (vertexWords, "main")
            fragment = (fragmentWords, "main")
        }

        do {
            try createSetLayout()
            try createPipelineLayout()
            pipeline = try InstancedQuadPipeline.create(
                device: device,
                renderPass: renderPass,
                layout: pipelineLayout!,
                vertex: vertex,
                fragment: fragment
            )
            try createDescriptorSet()
        } catch {
            destroy()
            throw error
        }
    }

    /// Per-frame uniform write — host-coherent, read by the next draw.
    func update(_ values: ShaderUniforms) {
        var copy = values
        uniforms.update(device: device, data: &copy, bytes: MemoryLayout<ShaderUniforms>.stride)
    }

    /// The argument buffer, whole. A list longer than the capacity is a
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

    /// Idempotent. The caller drains the GPU first.
    func destroy() {
        if let pipeline { vkDestroyPipeline(device, pipeline, nil) }
        if let pipelineLayout { vkDestroyPipelineLayout(device, pipelineLayout, nil) }
        if let setLayout { vkDestroyDescriptorSetLayout(device, setLayout, nil) }
        if let descriptorPool { vkDestroyDescriptorPool(device, descriptorPool, nil) }
        uniforms.destroy(device: device)
        arguments?.destroy(device: device)
        arguments = nil
        pipeline = nil
        pipelineLayout = nil
        setLayout = nil
        descriptorPool = nil
        descriptorSet = nil
        uniforms = BufferAndMemory()
    }

    // MARK: - Creation

    private static let bothStages = VkShaderStageFlags(
        VK_SHADER_STAGE_VERTEX_BIT.rawValue | VK_SHADER_STAGE_FRAGMENT_BIT.rawValue
    )

    private func createSetLayout() throws {
        var uniform = VkDescriptorSetLayoutBinding()
        uniform.binding = 1
        uniform.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
        uniform.descriptorCount = 1
        uniform.stageFlags = Self.bothStages

        var bindings = [uniform]
        if arguments != nil {
            var storage = VkDescriptorSetLayoutBinding()
            storage.binding = 3
            storage.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
            storage.descriptorCount = 1
            storage.stageFlags = Self.bothStages
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

    private func createDescriptorSet() throws {
        var sizes = [
            VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, descriptorCount: 1),
        ]
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

        var bufferInfo = VkDescriptorBufferInfo()
        bufferInfo.buffer = uniforms.buffer
        bufferInfo.offset = 0
        bufferInfo.range = VkDeviceSize(MemoryLayout<ShaderUniforms>.stride)

        var argumentInfo = VkDescriptorBufferInfo()
        argumentInfo.buffer = arguments?.buffer
        argumentInfo.offset = 0
        argumentInfo.range = VkDeviceSize(VK_WHOLE_SIZE)

        withUnsafePointer(to: &bufferInfo) { bufferPtr in
            withUnsafePointer(to: &argumentInfo) { argumentPtr in
                var writeUniform = VkWriteDescriptorSet()
                writeUniform.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
                writeUniform.dstSet = descriptorSet
                writeUniform.dstBinding = 1
                writeUniform.descriptorCount = 1
                writeUniform.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
                writeUniform.pBufferInfo = bufferPtr

                var writes = [writeUniform]
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
