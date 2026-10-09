// SPDX-License-Identifier: BSD-3-Clause

// Loinnir (sdk.md §5): the SDK's GPU library over Vulkan, in the "No
// Graphics API" style. One device and queue, one bindless texture heap,
// one pipeline layout (the heap plus a root pointer per draw), memory by
// GPU address, and a 64-bit timeline for every submission.
//
//   let gpu = try Loinnir.open(window: win, loop: &loop)
//   let verts = try gpu.alloc(.upload, bytes: 64 << 10)
//   let pso = try gpu.pipeline(vertex: vs, fragment: fs, target: .bgra8)
//   if let target = try gpu.frame(&loop, config) {
//     var cmd = try gpu.commands()
//     cmd.render(to: target, clear: (0, 0, 0, 1)) { r in r.draw(pso, root: verts.address, vertices: 3) }
//     try gpu.present(&loop, config, after: try gpu.submit(cmd))
//   }

import Todhchai

public final class Loinnir {
  public let gpu: GPUContext
  let heap: Heap
  let pipelineLayout: VkPipelineLayout
  let timeline: VkSemaphore
  public private(set) var timelineValue: UInt64 = 0
  var allocations: [GPUAllocation] = []
  var textures: [UInt32: ImageRecord] = [:]
  var pipelines: [VkPipeline] = []
  var pending: [(value: UInt64, commands: VkCommandBuffer)] = []

  // The window, if there is one.
  public let window: WindowID?
  let feedback: DmabufFeedback?
  var ring: ImageRing?
  var current: Int?  // the ring slot of the frame being drawn

  /// The GPU the compositor uses, for drawing into `window`.
  public static func open(window: WindowID, loop: inout Loop) throws(LoinnirError) -> Loinnir {
    let feedback: DmabufFeedback
    do {
      feedback = try loop.dmabufFeedback()
    } catch {
      throw .window(error)
    }
    return try Loinnir(gpu: try GPUContext(matching: feedback), window: window, feedback: feedback)
  }

  /// A GPU with no window, for offscreen work and tests.
  public static func headless() throws(LoinnirError) -> Loinnir {
    try Loinnir(gpu: try GPUContext(), window: nil, feedback: nil)
  }

  init(gpu: GPUContext, window: WindowID?, feedback: DmabufFeedback?) throws(LoinnirError) {
    self.gpu = gpu
    self.window = window
    self.feedback = feedback
    let c = gpu.vk.commands
    heap = try Heap(gpu)

    // The one pipeline layout: the heap, and 16 bytes of push constants
    // (the root pointer, and 8 bytes spare).
    var range = VkPushConstantRange(stageFlags: VK_SHADER_STAGE_ALL.rawValue, offset: 0, size: 16)
    var setLayout: VkDescriptorSetLayout? = heap.layout
    var layout: VkPipelineLayout?
    let r: VkResult = withUnsafePointer(to: &setLayout) { lp in
      withUnsafePointer(to: &range) { rp in
        var info = VkPipelineLayoutCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
        info.setLayoutCount = 1
        info.pSetLayouts = lp
        info.pushConstantRangeCount = 1
        info.pPushConstantRanges = rp
        return c.vkCreatePipelineLayout!(gpu.device, &info, nil, &layout)
      }
    }
    try check(r, "vkCreatePipelineLayout")
    pipelineLayout = layout!

    // The timeline.
    var typeInfo = VkSemaphoreTypeCreateInfo()
    typeInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO
    typeInfo.semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE
    var semaphore: VkSemaphore?
    let s: VkResult = withUnsafePointer(to: &typeInfo) { tp in
      var info = VkSemaphoreCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
      info.pNext = UnsafeRawPointer(tp)
      return c.vkCreateSemaphore!(gpu.device, &info, nil, &semaphore)
    }
    try check(s, "vkCreateSemaphore (timeline)")
    timeline = semaphore!
  }

  deinit {
    let c = gpu.vk.commands
    _ = c.vkDeviceWaitIdle!(gpu.device)
    ring = nil
    for (_, cb) in pending {
      var b: VkCommandBuffer? = cb
      c.vkFreeCommandBuffers!(gpu.device, gpu.commandPool, 1, &b)
    }
    for p in pipelines { c.vkDestroyPipeline!(gpu.device, p, nil) }
    for t in textures.values {
      c.vkDestroyImageView!(gpu.device, t.view, nil)
      c.vkDestroyImage!(gpu.device, t.image, nil)
      if let m = t.memory { c.vkFreeMemory!(gpu.device, m, nil) }
    }
    for a in allocations {
      c.vkDestroyBuffer!(gpu.device, a.buffer, nil)
      c.vkFreeMemory!(gpu.device, a.memory, nil)
    }
    c.vkDestroySemaphore!(gpu.device, timeline, nil)
    c.vkDestroyPipelineLayout!(gpu.device, pipelineLayout, nil)
    heap.destroy(gpu)
  }

  /// The DRM format modifier the window's images use (once made).
  public var modifier: UInt64? { ring?.modifier }

  // MARK: Pipelines

  /// A graphics pipeline from SPIR-V: vertex and fragment shaders reading
  /// their inputs through the root pointer and the heap, drawing triangles
  /// into one color target with alpha blending.
  public func pipeline(vertex: [UInt8], fragment: [UInt8], target: TextureFormat) throws(LoinnirError) -> Pipeline {
    let c = gpu.vk.commands
    func module(_ code: [UInt8]) throws(LoinnirError) -> VkShaderModule {
      guard code.count % 4 == 0, code.count >= 20 else { throw .unsupported("not SPIR-V (\(code.count) bytes)") }
      var m: VkShaderModule?
      let r: VkResult = code.withUnsafeBytes { bytes in
        var info = VkShaderModuleCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
        info.codeSize = code.count
        info.pCode = bytes.baseAddress!.assumingMemoryBound(to: UInt32.self)
        return c.vkCreateShaderModule!(gpu.device, &info, nil, &m)
      }
      try check(r, "vkCreateShaderModule")
      return m!
    }
    let vs = try module(vertex), fs = try module(fragment)
    defer {
      c.vkDestroyShaderModule!(gpu.device, vs, nil)
      c.vkDestroyShaderModule!(gpu.device, fs, nil)
    }
    var pipeline: VkPipeline?
    var format = target.vk
    let r: VkResult = "main".withCString { entry in
      var stages = [VkPipelineShaderStageCreateInfo](repeating: VkPipelineShaderStageCreateInfo(), count: 2)
      for (i, (stage, m)) in [(VK_SHADER_STAGE_VERTEX_BIT, vs), (VK_SHADER_STAGE_FRAGMENT_BIT, fs)].enumerated() {
        stages[i].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
        stages[i].stage = stage
        stages[i].module = m
        stages[i].pName = entry
      }
      var vertexInput = VkPipelineVertexInputStateCreateInfo()
      vertexInput.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
      var assembly = VkPipelineInputAssemblyStateCreateInfo()
      assembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
      assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
      var viewport = VkPipelineViewportStateCreateInfo()
      viewport.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
      viewport.viewportCount = 1
      viewport.scissorCount = 1
      var raster = VkPipelineRasterizationStateCreateInfo()
      raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
      raster.polygonMode = VK_POLYGON_MODE_FILL
      raster.cullMode = VK_CULL_MODE_NONE.rawValue
      raster.lineWidth = 1
      var multisample = VkPipelineMultisampleStateCreateInfo()
      multisample.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
      multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT
      var attachment = VkPipelineColorBlendAttachmentState()
      attachment.blendEnable = 1
      attachment.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA
      attachment.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
      attachment.colorBlendOp = VK_BLEND_OP_ADD
      attachment.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE
      attachment.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
      attachment.alphaBlendOp = VK_BLEND_OP_ADD
      attachment.colorWriteMask = 0xf
      var dynamicStates = [VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR]
      return withUnsafePointer(to: &attachment) { ap in
        var blend = VkPipelineColorBlendStateCreateInfo()
        blend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
        blend.attachmentCount = 1
        blend.pAttachments = ap
        return dynamicStates.withUnsafeMutableBufferPointer { dp in
          var dynamic = VkPipelineDynamicStateCreateInfo()
          dynamic.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
          dynamic.dynamicStateCount = 2
          dynamic.pDynamicStates = UnsafePointer(dp.baseAddress)
          return withUnsafePointer(to: &format) { fp in
            var rendering = VkPipelineRenderingCreateInfo()
            rendering.sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO
            rendering.colorAttachmentCount = 1
            rendering.pColorAttachmentFormats = fp
            return withUnsafePointer(to: &rendering) { rp in
              stages.withUnsafeBufferPointer { sp in
                var info = VkGraphicsPipelineCreateInfo()
                info.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
                info.pNext = UnsafeRawPointer(rp)
                info.stageCount = 2
                info.pStages = sp.baseAddress
                return withUnsafePointer(to: &vertexInput) { vi in
                  withUnsafePointer(to: &assembly) { ia in
                    withUnsafePointer(to: &viewport) { vp in
                      withUnsafePointer(to: &raster) { ra in
                        withUnsafePointer(to: &multisample) { ms in
                          withUnsafePointer(to: &blend) { bl in
                            withUnsafePointer(to: &dynamic) { dy in
                              info.pVertexInputState = vi
                              info.pInputAssemblyState = ia
                              info.pViewportState = vp
                              info.pRasterizationState = ra
                              info.pMultisampleState = ms
                              info.pColorBlendState = bl
                              info.pDynamicState = dy
                              info.layout = pipelineLayout
                              return c.vkCreateGraphicsPipelines!(gpu.device, nil, 1, &info, nil, &pipeline)
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    try check(r, "vkCreateGraphicsPipelines")
    pipelines.append(pipeline!)
    return Pipeline(pipeline: pipeline!)
  }

  // MARK: Commands and the timeline

  /// A command list to record into.
  public func commands() throws(LoinnirError) -> CommandList {
    reclaim()
    let c = gpu.vk.commands
    var info = VkCommandBufferAllocateInfo()
    info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
    info.commandPool = gpu.commandPool
    info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
    info.commandBufferCount = 1
    var cb: VkCommandBuffer?
    try check(c.vkAllocateCommandBuffers!(gpu.device, &info, &cb), "vkAllocateCommandBuffers")
    var begin = VkCommandBufferBeginInfo()
    begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT.rawValue
    _ = c.vkBeginCommandBuffer!(cb, &begin)
    var heapSet: VkDescriptorSet? = heap.set
    for point in [VK_PIPELINE_BIND_POINT_GRAPHICS, VK_PIPELINE_BIND_POINT_COMPUTE] {
      c.vkCmdBindDescriptorSets!(cb, point, pipelineLayout, 0, 1, &heapSet, 0, nil)
    }
    return CommandList(owner: self, cb: cb!)
  }

  /// Submits a recorded list. The GPU signals the returned timeline value
  /// when it's done.
  @discardableResult
  public func submit(_ list: consuming CommandList) throws(LoinnirError) -> UInt64 {
    let c = gpu.vk.commands
    let cb = list.cb
    _ = c.vkEndCommandBuffer!(cb)
    timelineValue += 1
    var value = timelineValue
    var signal: VkSemaphore? = timeline
    var buffer: VkCommandBuffer? = cb
    let r: VkResult = withUnsafePointer(to: &value) { vp in
      var timelineInfo = VkTimelineSemaphoreSubmitInfo()
      timelineInfo.sType = VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO
      timelineInfo.signalSemaphoreValueCount = 1
      timelineInfo.pSignalSemaphoreValues = vp
      return withUnsafePointer(to: &timelineInfo) { tp in
        withUnsafePointer(to: &signal) { sp in
          withUnsafePointer(to: &buffer) { bp in
            var submit = VkSubmitInfo()
            submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
            submit.pNext = UnsafeRawPointer(tp)
            submit.commandBufferCount = 1
            submit.pCommandBuffers = bp
            submit.signalSemaphoreCount = 1
            submit.pSignalSemaphores = sp
            return c.vkQueueSubmit!(gpu.queue, 1, &submit, nil)
          }
        }
      }
    }
    try check(r, "vkQueueSubmit")
    pending.append((timelineValue, cb))
    return timelineValue
  }

  /// Waits until the GPU has reached `value` on the timeline.
  public func wait(_ value: UInt64) throws(LoinnirError) {
    let c = gpu.vk.commands
    var semaphore: VkSemaphore? = timeline
    var v = value
    let r: VkResult = withUnsafePointer(to: &semaphore) { sp in
      withUnsafePointer(to: &v) { vp in
        var info = VkSemaphoreWaitInfo()
        info.sType = VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO
        info.semaphoreCount = 1
        info.pSemaphores = sp
        info.pValues = vp
        return c.vkWaitSemaphores!(gpu.device, &info, UInt64.max)
      }
    }
    try check(r, "vkWaitSemaphores")
    reclaim()
  }

  /// The timeline value the GPU has finished.
  public var completed: UInt64 {
    var v: UInt64 = 0
    _ = gpu.vk.commands.vkGetSemaphoreCounterValue!(gpu.device, timeline, &v)
    return v
  }

  /// Frees command buffers the GPU is done with.
  func reclaim() {
    let done = completed
    let c = gpu.vk.commands
    pending.removeAll { p in
      guard p.value <= done else { return false }
      var b: VkCommandBuffer? = p.commands
      c.vkFreeCommandBuffers!(gpu.device, gpu.commandPool, 1, &b)
      return true
    }
  }

  // MARK: The window

  /// The image to draw this frame into, sized for `config`; nil if every
  /// image is still with the compositor (draw on the next frame).
  public func frame(_ loop: inout Loop, _ config: Configure) throws(LoinnirError) -> RenderTarget? {
    guard let window, let feedback else { throw .unsupported("this Loinnir has no window") }
    if ring == nil || ring!.width != config.pixelWidth || ring!.height != config.pixelHeight {
      if ring != nil { try wait(timelineValue) }
      ring = nil
      loop.releaseGPUBuffers(window)
      ring = try ImageRing(gpu, window: window, width: config.pixelWidth, height: config.pixelHeight,
                           feedback: feedback, loop: &loop)
    }
    guard let ring, let i = ring.free(loop) else { return nil }
    current = i
    return .backbuffer(ring.records[i])
  }

  /// Presents the frame `frame` returned, once the GPU reaches `value`
  /// (v0: the CPU waits for it).
  public func present(_ loop: inout Loop, _ config: Configure, after value: UInt64) throws(LoinnirError) {
    guard let window, let ring, let i = current else { return }
    try wait(value)
    current = nil
    do {
      try loop.present(window, gpuBuffer: ring.slots[i].buffer, configSeq: config.configSeq)
    } catch {
      throw .window(error)
    }
  }

  /// Clears a frame to `color` and presents it. False if every image is
  /// still with the compositor.
  @discardableResult
  public func clear(_ color: (Float, Float, Float, Float), loop: inout Loop, config: Configure) throws(LoinnirError)
    -> Bool
  {
    guard let target = try frame(&loop, config) else { return false }
    var cmd = try commands()
    cmd.render(to: target, clear: color) { _ in }
    try present(&loop, config, after: try submit(cmd))
    return true
  }
}

/// A compiled pipeline.
public struct Pipeline: @unchecked Sendable {
  let pipeline: VkPipeline
}

/// What a render pass draws into.
public enum RenderTarget {
  case texture(Texture)
  /// The window's image for this frame (from `frame`).
  case backbuffer(ImageRecord)
}
