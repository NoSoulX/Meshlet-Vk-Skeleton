package meshlet_vulkan

import vk "vendor:vulkan"

MAX_FRAMES_IN_FLIGHT :: 2

when ODIN_DEBUG {
    Debug_Messenger_Type :: vk.DebugUtilsMessengerEXT
} else {
    Debug_Messenger_Type :: struct {} // 0 bytes on release
}

Swapchain_Context :: struct {
	handle:           vk.SwapchainKHR,
	format:           vk.Format,
	extent:           vk.Extent2D,
	
	// Swapchain pictures and their resources
	images:           []vk.Image,
	image_views:      []vk.ImageView,
	framebuffers:     [dynamic]vk.Framebuffer, // if using render pass
	
	// Synchronization (Frame-based)
	image_available_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
	render_finished_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
	in_flight_fences:           [MAX_FRAMES_IN_FLIGHT]vk.Fence,
	
	current_frame:    int, // Keeps book on in flight (0..MAX_FRAMES_IN_FLIGHT-1)
}

Queue :: struct {
    graphics_queue : vk.Queue,
    present_queue : vk.Queue,
    // transfer_queue : vk.Queue,
    // compute_queue : vk.Queue,
}

Queue_Family_Index :: struct {
    graphics_family : u32,
    present_family : u32,
    // compute_family : u32,
    // transfer_family : u32,
}

Vulkan_Context :: struct {
    instance : vk.Instance,
    logical_device : vk.Device,
    surface : vk.SurfaceKHR,
    physical_device : vk.PhysicalDevice,
    debug_messenger : Debug_Messenger_Type,
    family_index : Queue_Family_Index,
    queue : Queue,
    swapchain : Swapchain_Context,
    render_pass : vk.RenderPass,
    pipeline_layout: vk.PipelineLayout,
    graphics_pipeline: vk.Pipeline,
    command_pool : vk.CommandPool,
    command_buffers : [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
    framebuffer_resized : bool
}