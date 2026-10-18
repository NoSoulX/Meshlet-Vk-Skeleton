package meshlet_vulkan

import "core:os"
import "core:fmt"
import "core:image"
import "core:log"
import "base:runtime"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"


validation_layers := [?]cstring{"VK_LAYER_KHRONOS_validation"}
device_extensions := [?]cstring{"VK_KHR_swapchain", "VK_EXT_mesh_shader"}

global_ctx : runtime.Context

cleanup :: proc(ctx : Vulkan_Context) {
    cleanup_swapchain(ctx)
    vk.DestroyPipeline(ctx.logical_device, ctx.graphics_pipeline, nil)
    vk.DestroyPipelineLayout(ctx.logical_device, ctx.pipeline_layout, nil)
    vk.DestroyRenderPass(ctx.logical_device, ctx.render_pass, nil)
    // vk.DestroyBuffer()
    // vk.FreeMemory()

    for i in 0..<MAX_FRAMES_IN_FLIGHT {
        vk.DestroySemaphore(ctx.logical_device, ctx.swapchain.render_finished_semaphores[i], nil)
        vk.DestroySemaphore(ctx.logical_device, ctx.swapchain.image_available_semaphores[i], nil)
        vk.DestroyFence(ctx.logical_device, ctx.swapchain.in_flight_fences[i], nil)
    }


    vk.DestroyCommandPool(ctx.logical_device, ctx.command_pool, nil)
    vk.DestroyDevice(ctx.logical_device, nil)
    when ODIN_DEBUG {
        vk.DestroyDebugUtilsMessengerEXT(ctx.instance, ctx.debug_messenger, nil)
    }

    vk.DestroySurfaceKHR(ctx.instance, ctx.surface, nil)
    vk.DestroyInstance(ctx.instance, nil)
}

cleanup_swapchain :: proc(ctx : Vulkan_Context) {
    for framebuffer in ctx.swapchain.framebuffers {
        vk.DestroyFramebuffer(ctx.logical_device, framebuffer, nil)
    }
    for image_view in ctx.swapchain.image_views {
        vk.DestroyImageView(ctx.logical_device, image_view, nil)
    }
    vk.DestroySwapchainKHR(ctx.logical_device, ctx.swapchain.handle, nil)
}

create_commandbuffer :: proc(logical_device : vk.Device, command_pool : vk.CommandPool, command_buffer : ^vk.CommandBuffer) {
    alloc_info := vk.CommandBufferAllocateInfo {
        sType = .COMMAND_BUFFER_ALLOCATE_INFO,
        commandPool = command_pool,
        level = .PRIMARY,
        commandBufferCount = 1,
    }

    if vk.AllocateCommandBuffers(logical_device, &alloc_info, command_buffer) != .SUCCESS {
        panic("Command buffer reservation failed!")
    }
}

create_commandpool :: proc(logical_device : vk.Device, queue_family_index : Queue_Family_Index, command_pool : ^vk.CommandPool) {
    pool_info := vk.CommandPoolCreateInfo {
        sType = .COMMAND_POOL_CREATE_INFO,
        flags = {.RESET_COMMAND_BUFFER},
        queueFamilyIndex = queue_family_index.graphics_family,
    }
    if vk.CreateCommandPool(logical_device, &pool_info, nil, command_pool) != .SUCCESS {
        panic("Failed to create graphics pool")
    }
}

create_graphics_pipeline :: proc(logical_device : vk.Device, render_pass : vk.RenderPass, pipeline_layout : ^vk.PipelineLayout, graphics_pipeline : ^vk.Pipeline) {
    mesh_code, mesh_err := os.read_entire_file("vulkan/shaders/compiled/mesh.spv", context.allocator)
    if mesh_err != nil {
        panic("Failed to read mesh shader!")
    }
    defer delete(mesh_code, context.allocator)

    frag_code, frag_err := os.read_entire_file("vulkan/shaders/compiled/frag.spv", context.allocator)
    if frag_err != nil {
        panic("Failed to read fragment shader!")
    }
    defer delete(frag_code, context.allocator)

    mesh_module := create_shader_module(logical_device, mesh_code)
    frag_module := create_shader_module(logical_device, frag_code)
    defer vk.DestroyShaderModule(logical_device, mesh_module, nil)
    defer vk.DestroyShaderModule(logical_device, frag_module, nil)

    shader_stages := [2]vk.PipelineShaderStageCreateInfo {
        {
            sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage  = {.MESH_EXT},
            module = mesh_module,
            pName  = "main",
        },
        {
            sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage  = {.FRAGMENT},
            module = frag_module,
            pName  = "main",
        },
    }

    vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
        sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    }

    viewport_state := vk.PipelineViewportStateCreateInfo {
        sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        viewportCount = 1,
        scissorCount  = 1,
    }

    rasterizer := vk.PipelineRasterizationStateCreateInfo {
        sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        cullMode    = {},
        frontFace   = .COUNTER_CLOCKWISE,
        lineWidth   = 1.0,
    }

    multisampling := vk.PipelineMultisampleStateCreateInfo {
        sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        rasterizationSamples = {._1},
    }

    color_blend_attachment := vk.PipelineColorBlendAttachmentState {
        colorWriteMask = {.R, .G, .B, .A},
    }

    color_blending := vk.PipelineColorBlendStateCreateInfo {
        sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        attachmentCount = 1,
        pAttachments    = &color_blend_attachment,
    }

    dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
    dynamic_state := vk.PipelineDynamicStateCreateInfo {
        sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        dynamicStateCount = u32(len(dynamic_states)),
        pDynamicStates    = &dynamic_states[0],
    }

    push_constant_range := vk.PushConstantRange {
        stageFlags = {.MESH_EXT},
        offset = 0,
        size = u32(size_of(Vertex) * 4),
    }

    layout_info := vk.PipelineLayoutCreateInfo {
        sType = .PIPELINE_LAYOUT_CREATE_INFO,
        pushConstantRangeCount = 1,
        pPushConstantRanges = &push_constant_range,
    }

    if vk.CreatePipelineLayout(logical_device, &layout_info, nil, pipeline_layout) != .SUCCESS {
        panic("Failed to create pipeline layout!")
    }

    pipeline_info := vk.GraphicsPipelineCreateInfo {
        sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
        stageCount          = u32(len(shader_stages)),
        pStages             = &shader_stages[0],
        pVertexInputState   = &vertex_input_info,
        pInputAssemblyState = nil,
        pViewportState      = &viewport_state,
        pRasterizationState = &rasterizer,
        pMultisampleState   = &multisampling,
        pColorBlendState    = &color_blending,
        pDynamicState       = &dynamic_state,
        layout              = pipeline_layout^,
        renderPass          = render_pass,
        subpass             = 0,
    }

    if vk.CreateGraphicsPipelines(logical_device, 0, 1, &pipeline_info, nil, graphics_pipeline) != .SUCCESS {
        panic("Failed to create graphics pipeline!")
    }
}

create_framebuffers :: proc (logical_device : vk.Device, render_pass : vk.RenderPass, swapchain : ^Swapchain_Context) {
    image_count := len(swapchain.image_views)
    swapchain.framebuffers = make([dynamic]vk.Framebuffer, image_count)    
    
    for i := 0; i < image_count; i += 1 {
		attachments := []vk.ImageView{swapchain.image_views[i]}

		framebuffer_info := vk.FramebufferCreateInfo {
			sType           = .FRAMEBUFFER_CREATE_INFO,
			renderPass      = render_pass,
			attachmentCount = u32(len(attachments)),
			pAttachments    = raw_data(attachments),
			width           = swapchain.extent.width,
			height          = swapchain.extent.height,
			layers          = 1,
		}

		if result := vk.CreateFramebuffer(logical_device, &framebuffer_info, nil, &swapchain.framebuffers[i]); result != .SUCCESS {
			panic("Error: Failed to create Framebuffer!")
		}
	}
}

create_imageviews :: proc(logical_device : vk.Device, swapchain : ^Swapchain_Context) {
    image_count : u32
    vk.GetSwapchainImagesKHR(logical_device, swapchain.handle, &image_count, nil)

    if image_count == 0 {
        panic("Swapchain has no images")
    }

    swapchain.images = make([]vk.Image, int(image_count))
    vk.GetSwapchainImagesKHR(logical_device, swapchain.handle, &image_count, raw_data(swapchain.images))

    swapchain.image_views = make([]vk.ImageView, int(image_count))
    for i := 0; i < len(swapchain.images); i += 1 {
        create_info := vk.ImageViewCreateInfo {
            sType = .IMAGE_VIEW_CREATE_INFO,
            image = swapchain.images[i],
            viewType = .D2,
            format = swapchain.format,
            components = {
                r = .IDENTITY,
                g = .IDENTITY,
                b = .IDENTITY,
                a = .IDENTITY,
            },
            subresourceRange = {
                aspectMask = {.COLOR},
                baseMipLevel = 0,
                levelCount = 1,
                baseArrayLayer = 0,
                layerCount = 1,
            }
        }
        result := vk.CreateImageView(logical_device, &create_info, nil, &swapchain.image_views[i])

        if result != .SUCCESS {
            fmt.panicf("Failed to create swapchain image view at index %d! Error: %v", i, result)
        }
    }
}

create_instance :: proc(instance: ^vk.Instance) {
    vk.load_proc_addresses(rawptr(sdl.Vulkan_GetVkGetInstanceProcAddr()))

    num_ext : u32
    ext := sdl.Vulkan_GetInstanceExtensions(&num_ext)

    app_info := vk.ApplicationInfo {
        sType = .APPLICATION_INFO,
        pApplicationName = "Skeleton",
        applicationVersion = vk.MAKE_VERSION(0, 0, 1),
        pEngineName = "No engine",
        engineVersion = vk.MAKE_VERSION(1, 0, 0),
        apiVersion = vk.API_VERSION_1_3,
    }

    create_info := vk.InstanceCreateInfo {
        sType = .INSTANCE_CREATE_INFO,
        pApplicationInfo = &app_info,
        ppEnabledExtensionNames = ext,
        enabledExtensionCount = num_ext,
    }

    when ODIN_DEBUG {
        layer_count : u32
        vk.EnumerateInstanceLayerProperties(&layer_count, nil)
        if layer_count > 0 {
            available_layers := make([]vk.LayerProperties, int(layer_count), context.temp_allocator)
            vk.EnumerateInstanceLayerProperties(&layer_count, raw_data(available_layers))

            for layer in available_layers {
                name := layer.layerName
                if cstring(&name[0]) == "VK_LAYER_KHRONOS_validation" {
                    create_info.enabledLayerCount = u32(len(validation_layers))
                    create_info.ppEnabledLayerNames = &validation_layers[0]
                    break
                }
            }
        }

        if create_info.enabledLayerCount > 0 {
            debug_create_info : vk.DebugUtilsMessengerCreateInfoEXT
            populate_debug_messenger(&debug_create_info)
            create_info.pNext = cast(rawptr)&debug_create_info
        }
    }

    if (vk.CreateInstance(&create_info, nil, instance) != .SUCCESS) {
        panic("Failed to create instance")
    }

    vk.load_proc_addresses_instance(instance^)
}

create_logical_device :: proc(physical_device : vk.PhysicalDevice, logical_device : ^vk.Device, surface: vk.SurfaceKHR, queue_index : ^Queue_Family_Index, queue : ^Queue) {
    find_queue_families(physical_device, surface, queue_index)
    if queue_index.graphics_family == max(u32) || queue_index.present_family == max(u32) {
        panic("Failed to find usable graphics and/or present queue families")
    }

    all_indices := [2]u32{queue_index.graphics_family, queue_index.present_family}

    unique_indices : [dynamic]u32
    defer delete(unique_indices)

    for idx in all_indices {
        found := false
        for u_idx in unique_indices {
            if idx == u_idx {
                found = true
                break
            }
        }
        if !found {
            append(&unique_indices, idx)
        }
    }

    queue_priority : f32 = 1.0
    queue_infos := make([]vk.DeviceQueueCreateInfo, len(unique_indices))
    defer delete(queue_infos)

    for family_idx, i in unique_indices {
        queue_infos[i] = vk.DeviceQueueCreateInfo {
            sType = .DEVICE_QUEUE_CREATE_INFO,
            queueFamilyIndex = family_idx,
            queueCount = 1,
            pQueuePriorities = &queue_priority,
        }
    }

    device_features := vk.PhysicalDeviceFeatures {
        samplerAnisotropy = true,
    }

    mesh_features := vk.PhysicalDeviceMeshShaderFeaturesEXT {
        sType = .PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT,
        taskShader = true,
        meshShader = true,
    }

    features2 := vk.PhysicalDeviceFeatures2 {
        sType = .PHYSICAL_DEVICE_FEATURES_2,
        pNext = &mesh_features,
        features = device_features,
    }

    create_info := vk.DeviceCreateInfo {
        sType = .DEVICE_CREATE_INFO,
        pNext = &features2,
        queueCreateInfoCount = u32(len(queue_infos)),
        pQueueCreateInfos = raw_data(queue_infos),
        enabledExtensionCount = u32(len(device_extensions)),
        ppEnabledExtensionNames = raw_data(device_extensions[:]),
    }

    if vk.CreateDevice(physical_device, &create_info, nil, logical_device) != .SUCCESS {
        panic("Failed to create logical device")
    }

    vk.load_proc_addresses_device(logical_device^)
    vk.GetDeviceQueue(logical_device^, queue_index.graphics_family, 0, &queue.graphics_queue)
    vk.GetDeviceQueue(logical_device^, queue_index.present_family, 0, &queue.present_queue)
    // vk.GetDeviceQueue(logical_device^, queue_index.transfer_family, 0, &queue.transfer_queue)
    // vk.GetDeviceQueue(logical_device^, queue_index.compute_family, 0, &queue.compute_queue)

}

create_renderpass :: proc(logical_device : vk.Device, swapchain : Swapchain_Context, render_pass : ^vk.RenderPass) {
    color_attachment := vk.AttachmentDescription {
        format = swapchain.format,
        samples = {._1},
        loadOp = .CLEAR,
        storeOp = .STORE,
        stencilLoadOp = .DONT_CARE,
        stencilStoreOp = .DONT_CARE,
        initialLayout = .UNDEFINED,
        finalLayout = .PRESENT_SRC_KHR,
    }

    color_attachment_ref := vk.AttachmentReference {
        attachment = 0,
        layout = .COLOR_ATTACHMENT_OPTIMAL,
    }

    subpass := vk.SubpassDescription {
        pipelineBindPoint = .GRAPHICS,
        colorAttachmentCount = 1,
        pColorAttachments = &color_attachment_ref,
    }

    dependency := vk.SubpassDependency {
        srcSubpass = vk.SUBPASS_EXTERNAL,
        dstSubpass = 0,
        srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
        srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
        dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
        dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
    }

    render_pass_info := vk.RenderPassCreateInfo {
        sType = .RENDER_PASS_CREATE_INFO,
        attachmentCount = 1,
        pAttachments = &color_attachment,
        subpassCount = 1,
        pSubpasses = &subpass,
        dependencyCount = 1,
        pDependencies = &dependency,
    }

    if (vk.CreateRenderPass(logical_device, &render_pass_info, nil, render_pass)) != .SUCCESS {
        panic("Failed to create renderpass")
    }

}

create_shader_module :: proc(logical_device : vk.Device, code: []byte) -> vk.ShaderModule {
    // Check, that SPIR-V-data is positioned correctly (it has to be divisible by 4 bytes)
    if len(code) % 4 != 0 {
        panic("SPIR-V-codes length is not divisible by 4!")
    }

    create_info := vk.ShaderModuleCreateInfo {
        sType    = .SHADER_MODULE_CREATE_INFO,
        codeSize = len(code),
        // Convert []byte (u8) to pointer ^u32, that Vulkan expects
        pCode    = (^u32)(raw_data(code)),
    }
    shader_module: vk.ShaderModule
    
    result := vk.CreateShaderModule(logical_device, &create_info, nil, &shader_module)
    if result != .SUCCESS {
        panic("Shader-module creation failed!")
    }
    return shader_module
}

create_surface :: proc(instance : vk.Instance, window : ^sdl.Window, surface : ^vk.SurfaceKHR) {
    if !sdl.Vulkan_CreateSurface(window, instance, nil, surface) {
        panic("Failed to create surface!")
    }
}

create_syncobjects :: proc(logical_device : vk.Device, swapchain : ^Swapchain_Context) {
    semaphore_info := vk.SemaphoreCreateInfo {
        sType = .SEMAPHORE_CREATE_INFO,
    }

    fence_info := vk.FenceCreateInfo {
        sType = .FENCE_CREATE_INFO,
        flags = {.SIGNALED},
    }

    for i in 0..<MAX_FRAMES_IN_FLIGHT {
        if vk.CreateSemaphore(logical_device, &semaphore_info, nil, &swapchain.image_available_semaphores[i]) != .SUCCESS {
            panic("Failed to create semaphore for image")
        }

        if vk.CreateSemaphore(logical_device, &semaphore_info, nil, &swapchain.render_finished_semaphores[i]) != .SUCCESS {
            panic("Failed to create semaphore for finished render")
        }

        if vk.CreateFence(logical_device, &fence_info, nil, &swapchain.in_flight_fences[i]) != .SUCCESS {
            panic("Failed to create fence")
        }
    }
}

create_swapchain :: proc(physical_device : vk.PhysicalDevice, logical_device : vk.Device, surface : vk.SurfaceKHR, details : ^Swapchain_Context) {
    capabilities : vk.SurfaceCapabilitiesKHR
    formats : [dynamic]vk.SurfaceFormatKHR
    present_modes : [dynamic]vk.PresentModeKHR

    defer delete(formats)
    defer delete(present_modes)

    vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, &capabilities)

    format_count : u32
    vk.GetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, nil)
    if format_count != 0 {
        formats = make([dynamic]vk.SurfaceFormatKHR, format_count)
        vk.GetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, raw_data(formats))
    }

    mode_count: u32
    vk.GetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &mode_count, nil)
    if mode_count > 0 {
        resize(&present_modes, int(mode_count))
        vk.GetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &mode_count, raw_data(present_modes))
    }

    chosen_format := formats[0] // By default select first format, but check optimal
    for f in formats {
        if f.format == .B8G8R8A8_SRGB && f.colorSpace == .COLORSPACE_SRGB_NONLINEAR {
            chosen_format = f
            break
        }
    }

    chosen_present_mode := vk.PresentModeKHR.FIFO // By default select default mode, but check optimal
    for m in present_modes {
        if m == .MAILBOX {
            chosen_present_mode = m
            break
        }
    }

    chosen_extent : vk.Extent2D
    if capabilities.currentExtent.width != u32(max(u32)) {
        chosen_extent = capabilities.currentExtent
    } else {
        chosen_extent = vk.Extent2D{width = 800, height = 600}
    }

    details.format = chosen_format.format
    details.extent = chosen_extent

    create_info := vk.SwapchainCreateInfoKHR {
        sType = .SWAPCHAIN_CREATE_INFO_KHR,
        surface = surface,
        minImageCount = capabilities.minImageCount + 1,
        imageFormat = chosen_format.format,
        imageColorSpace = chosen_format.colorSpace,
        imageExtent = chosen_extent,
        imageArrayLayers = 1,
        imageUsage = {.COLOR_ATTACHMENT},
        imageSharingMode = .EXCLUSIVE,
        preTransform = capabilities.currentTransform,
        compositeAlpha = {.OPAQUE},
        presentMode = chosen_present_mode,
        clipped = true,
    }

    if capabilities.maxImageCount > 0 && create_info.minImageCount > capabilities.maxImageCount {
        create_info.minImageCount = capabilities.maxImageCount
    }

    result := vk.CreateSwapchainKHR(logical_device, &create_info, nil, &details.handle)
    if result != .SUCCESS {
        panic("Swapchain creation failed!")
    }
}

debug_callback :: proc "system" (
	messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
	messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
	pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
	pUserData: rawptr) -> b32 {
        
	context = global_ctx

	level: log.Level
	if .ERROR in messageSeverity {
		level = .Error
	} else if .WARNING in messageSeverity {
		level = .Warning
	} else if .INFO in messageSeverity {
		level = .Info
	} else {
		level = .Debug
	}

	log.logf(level, "vulkan[%v]: %s", messageTypes, pCallbackData.pMessage)
	return false
}

find_queue_families :: proc(physical_device : vk.PhysicalDevice, surface: vk.SurfaceKHR, queue : ^Queue_Family_Index) {
    queue.graphics_family = max(u32)
    queue.present_family = max(u32)
    // queue.transfer_family = max(u32)
    // queue.compute_family = max(u32)


    queue_family_count : u32
    vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, nil)
    if queue_family_count == 0 {
        panic("Failed to find queues")
    }

    queue_families := make([]vk.QueueFamilyProperties, queue_family_count)
    defer delete(queue_families)
    vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, raw_data(queue_families))

    for prop, i in queue_families {
        u32_idx := u32(i)

        if .GRAPHICS in prop.queueFlags {
            if queue.graphics_family == max(u32) {
                queue.graphics_family = u32_idx
            }
        }

        present_support : b32
        vk.GetPhysicalDeviceSurfaceSupportKHR(physical_device, u32_idx, surface, &present_support)
            if present_support && queue.present_family == max(u32) {
            queue.present_family = u32_idx
        }
        /*
        if .COMPUTE in prop.queueFlags {
            if !(.GRAPHICS in prop.queueFlags) {
                queue.compute_family = u32_idx // Found ideal dedicated compute queue!
            } else if queue.compute_family == max(u32) {
                queue.compute_family = u32_idx // Fallback to shared compute
            }
        }

        if .TRANSFER in prop.queueFlags {
            if !(.GRAPHICS in prop.queueFlags) && !(.COMPUTE in prop.queueFlags) {
                queue.transfer_family = u32_idx // Found ideal dedicated transfer queue!
            } else if queue.transfer_family == max(u32) {
                queue.transfer_family = u32_idx // Fallback to shared transfer
            }
        } */
    }
}

init_vulkan :: proc(ctx : ^Vulkan_Context, window : ^sdl.Window) {
    create_instance(&ctx.instance)
    when ODIN_DEBUG {
        setup_debug_messenger(ctx.instance, &ctx.debug_messenger)
    }
    create_surface(ctx.instance,window, &ctx.surface)
    select_device(ctx.instance, &ctx.physical_device)
    create_logical_device(ctx.physical_device, &ctx.logical_device, ctx.surface, &ctx.family_index, &ctx.queue)
    create_swapchain(ctx.physical_device, ctx.logical_device, ctx.surface ,&ctx.swapchain)
    create_imageviews(ctx.logical_device, &ctx.swapchain)
    create_renderpass(ctx.logical_device, ctx.swapchain, &ctx.render_pass)
    create_graphics_pipeline(ctx.logical_device, ctx.render_pass, &ctx.pipeline_layout, &ctx.graphics_pipeline)
    create_framebuffers(ctx.logical_device, ctx.render_pass, &ctx.swapchain)
    create_commandpool(ctx.logical_device, ctx.family_index ,&ctx.command_pool)
    for i in 0..<MAX_FRAMES_IN_FLIGHT {
        create_commandbuffer(ctx.logical_device, ctx.command_pool, &ctx.command_buffers[i])
    }
    create_syncobjects(ctx.logical_device, &ctx.swapchain)
}

is_device_suitable :: proc(device : vk.PhysicalDevice) -> bool {
    extension_count : u32
    vk.EnumerateDeviceExtensionProperties(device, nil, &extension_count, nil)
    if extension_count == 0 {
        return false
    }

    extensions := make([]vk.ExtensionProperties, extension_count, context.temp_allocator)
    vk.EnumerateDeviceExtensionProperties(device, nil, &extension_count, raw_data(extensions))

    has_swapchain := false
    has_mesh_shader := false
    for ext in extensions {
        name := ext.extensionName
        if cstring(&name[0]) == "VK_KHR_swapchain" {
            has_swapchain = true
        }
        if cstring(&name[0]) == "VK_EXT_mesh_shader" {
            has_mesh_shader = true
        }
    }
    if !has_swapchain || !has_mesh_shader {
        return false
    }

    mesh_features := vk.PhysicalDeviceMeshShaderFeaturesEXT {
        sType = .PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT,
    }

    features2 := vk.PhysicalDeviceFeatures2 {
        sType = .PHYSICAL_DEVICE_FEATURES_2,
        pNext = &mesh_features,
    }

    vk.GetPhysicalDeviceFeatures2(device, &features2)
    if !bool(mesh_features.taskShader) || !bool(mesh_features.meshShader) {
        return false
    }

    props: vk.PhysicalDeviceProperties
    vk.GetPhysicalDeviceProperties(device, &props)
    switch props.deviceType {
    case .DISCRETE_GPU, .INTEGRATED_GPU, .VIRTUAL_GPU, .OTHER, .CPU:
        return true
    case:
        return false
    }
}

@(disabled = !ODIN_DEBUG)
populate_debug_messenger :: proc(create_info : ^vk.DebugUtilsMessengerCreateInfoEXT) {
    create_info.sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT
    create_info.messageSeverity = {.VERBOSE, .INFO, .WARNING, .ERROR}
    create_info.messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE, .DEVICE_ADDRESS_BINDING}
    create_info.pfnUserCallback = debug_callback
}

draw_frame :: proc(ctx : ^Vulkan_Context) {
    frame_idx := ctx.swapchain.current_frame
    image_index : u32
    command_buffer := ctx.command_buffers[frame_idx]

    if result := vk.WaitForFences(ctx.logical_device, 1, &ctx.swapchain.in_flight_fences[frame_idx], true, max(u64)); result != .SUCCESS {
        fmt.panicf("Failed to wait for fence: %v", result)
    }

    if result := vk.ResetFences(ctx.logical_device, 1, &ctx.swapchain.in_flight_fences[frame_idx]); result != .SUCCESS {
        panic("Failed to reset fence")
    }

    if result := vk.ResetCommandBuffer(command_buffer, {}); result != .SUCCESS {
        panic("Failed to reset command buffer")
    }

    acquire_result := vk.AcquireNextImageKHR(ctx.logical_device, ctx.swapchain.handle, max(u64), ctx.swapchain.image_available_semaphores[frame_idx], 0, &image_index)
    if acquire_result == .ERROR_OUT_OF_DATE_KHR || acquire_result == .SUBOPTIMAL_KHR {
        return
    }
    if acquire_result != .SUCCESS {
        panic("Failed to acquire swapchain image")
    }

    meshlet_vertices := [4]Vertex{
        { pos = {-0.75,  0.75}, color = {1.0, 0.0, 0.0, 1.0} },
        { pos = { 0.75,  0.75}, color = {0.0, 1.0, 0.0, 1.0} },
        { pos = { 0.75, -0.75}, color = {0.0, 0.0, 1.0, 1.0} },
        { pos = {-0.75, -0.75}, color = {1.0, 1.0, 1.0, 1.0} },
    }

    begin_info := vk.CommandBufferBeginInfo{ sType = .COMMAND_BUFFER_BEGIN_INFO }
    if vk.BeginCommandBuffer(command_buffer, &begin_info) != .SUCCESS {
        panic("Failed to begin command buffer recording!")
    }

    attachment := vk.RenderingAttachmentInfo {
        sType = .RENDERING_ATTACHMENT_INFO,
        imageView = ctx.swapchain.image_views[image_index],
        imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
        loadOp = .CLEAR,
        storeOp = .STORE,
        clearValue = vk.ClearValue {
            color = vk.ClearColorValue {
                float32 = [4]f32 { 0.1, 0.1, 0.1, 1.0 }
            }
        },
    }

    render_info := vk.RenderingInfo {
        sType = .RENDERING_INFO,
        renderArea = { offset = { x = 0, y = 0 }, extent = ctx.swapchain.extent },
        layerCount = 1,
        colorAttachmentCount = 1,
        pColorAttachments = &attachment,
    }

    viewport := vk.Viewport {
        x = 0,
        y = 0,
        width = f32(ctx.swapchain.extent.width),
        height = f32(ctx.swapchain.extent.height),
        minDepth = 0,
        maxDepth = 1,
    }

    scissor := vk.Rect2D {
        offset = { x = 0, y = 0 },
        extent = ctx.swapchain.extent,
    }

    vk.CmdBeginRendering(command_buffer, &render_info)
    vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
    vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
    vk.CmdBindPipeline(command_buffer, .GRAPHICS, ctx.graphics_pipeline)
    vk.CmdPushConstants(command_buffer, ctx.pipeline_layout, {.MESH_EXT}, 0, u32(size_of(Vertex) * len(meshlet_vertices)), &meshlet_vertices[0])
    vk.CmdDrawMeshTasksEXT(command_buffer, 1, 1, 1)
    vk.CmdEndRendering(command_buffer)

    if vk.EndCommandBuffer(command_buffer) != .SUCCESS {
        panic("Failed to end recording of command buffer!")
    }

    wait_stage_mask := vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}
    submit_info := vk.SubmitInfo {
        sType = .SUBMIT_INFO,
        waitSemaphoreCount = 1,
        pWaitSemaphores = &ctx.swapchain.image_available_semaphores[frame_idx],
        pWaitDstStageMask = &wait_stage_mask,
        commandBufferCount = 1,
        pCommandBuffers = &command_buffer,
        signalSemaphoreCount = 1,
        pSignalSemaphores = &ctx.swapchain.render_finished_semaphores[frame_idx],
    }

    if vk.QueueSubmit(ctx.queue.graphics_queue, 1, &submit_info, ctx.swapchain.in_flight_fences[frame_idx]) != .SUCCESS {
        panic("Failed to submit draw command buffer")
    }

    present_info := vk.PresentInfoKHR {
        sType = .PRESENT_INFO_KHR,
        waitSemaphoreCount = 1,
        pWaitSemaphores = &ctx.swapchain.render_finished_semaphores[frame_idx],
        swapchainCount = 1,
        pSwapchains = &ctx.swapchain.handle,
        pImageIndices = &image_index,
    }

    if result := vk.QueuePresentKHR(ctx.queue.present_queue, &present_info); result != .SUCCESS && result != .SUBOPTIMAL_KHR {
        panic("Failed to present swapchain image")
    }

    ctx.swapchain.current_frame = (frame_idx + 1) % MAX_FRAMES_IN_FLIGHT
}

recreate_swapchain :: proc(ctx : ^Vulkan_Context, window : ^sdl.Window) {
    width, height : i32 = 0, 0
    sdl.GetWindowSizeInPixels(window, &width, &height)

    if width == 0 || height == 0 {
        return
    }

    vk.DeviceWaitIdle(ctx.logical_device)
    cleanup_swapchain(ctx^)

    create_swapchain(ctx.physical_device, ctx.logical_device, ctx.surface, &ctx.swapchain)
    create_imageviews(ctx.logical_device, &ctx.swapchain)
    create_framebuffers(ctx.logical_device, ctx.render_pass, &ctx.swapchain)

}

select_device :: proc(instance : vk.Instance, physical_device : ^vk.PhysicalDevice) {
    device_count : u32
    vk.EnumeratePhysicalDevices(instance, &device_count, nil)
    if device_count == 0 {
        panic("Failed to find GPU with Vulkan support")
    }

    best_device : vk.PhysicalDevice
    best_priority : i32 = -1

    devices := make([]vk.PhysicalDevice, device_count, context.temp_allocator)
    vk.EnumeratePhysicalDevices(instance, &device_count, raw_data(devices))
    for device in devices {
        if !is_device_suitable(device) {
            continue
        }

        props: vk.PhysicalDeviceProperties
        vk.GetPhysicalDeviceProperties(device, &props)

        priority : i32 = 0
        switch props.deviceType {
            case .DISCRETE_GPU:
                priority = 4
            case .INTEGRATED_GPU:
                priority = 3
            case .VIRTUAL_GPU:
                priority = 2
            case .OTHER:
                priority = 1
            case .CPU:
                priority = 0
        }

        if priority > best_priority {
            best_priority = priority
            best_device = device
        }
    }

    if best_device == nil {
        panic("Failed to find suitable GPU that meets minimum requirements")
    }

    physical_device^ = best_device
}

@(disabled = !ODIN_DEBUG)
setup_debug_messenger :: proc(instance : vk.Instance, debug_messenger : ^vk.DebugUtilsMessengerEXT) {
    create_info : vk.DebugUtilsMessengerCreateInfoEXT
    populate_debug_messenger(&create_info)

    if(vk.CreateDebugUtilsMessengerEXT(instance, &create_info, nil, debug_messenger)) != .SUCCESS {
        panic("Failed to set up debug messenger")
    }
}