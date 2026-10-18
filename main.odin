package bucket

import "core:log"
import sdl "vendor:sdl3"
import "vulkan"

MIN_WINDOW_WIDTH  :: 640
MIN_WINDOW_HEIGHT :: 480

mark_resize_if_changed :: proc(window: ^sdl.Window, event: sdl.Event, last_width: ^i32, last_height: ^i32, framebuffer_resized: ^bool) {
    if event.type != .WINDOW_RESIZED && event.type != .WINDOW_PIXEL_SIZE_CHANGED {
        return
    }

    width := i32(event.window.data1)
    height := i32(event.window.data2)

    if width < MIN_WINDOW_WIDTH {
        width = MIN_WINDOW_WIDTH
    }
    if height < MIN_WINDOW_HEIGHT {
        height = MIN_WINDOW_HEIGHT
    }

    if width > 0 && height > 0 && (width != last_width^ || height != last_height^) {
        last_width^ = width
        last_height^ = height
        framebuffer_resized^ = true
    }
}

main :: proc() {
    vkctx : vulkan.Vulkan_Context
    last_window_width : i32 = -1
    last_window_height : i32 = -1

    when ODIN_DEBUG {
        context.logger = log.create_console_logger()
        vulkan.global_ctx = context
    }

    if !sdl.Init({.VIDEO}) {
        panic("Failed to initialize")
    } 

    window := sdl.CreateWindow("Meshlet Skeleton",800,600,{.VULKAN, .RESIZABLE})
    if window == nil {
        panic("Failed to create window")
    }

    sdl.SetWindowMinimumSize(window, MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT)

    vulkan.init_vulkan(&vkctx, window)
    
    event_loop : for {
        event : sdl.Event
        for sdl.PollEvent(&event) {
            #partial switch event.type {
                case .QUIT:
                    break event_loop
                case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED:
                    mark_resize_if_changed(window, event, &last_window_width, &last_window_height, &vkctx.framebuffer_resized)
            }
        }

        if vkctx.framebuffer_resized {
            width, height : i32
            sdl.GetWindowSizeInPixels(window, &width, &height)
            if width == 0 || height == 0 {
                vkctx.framebuffer_resized = false
                continue
            }
            if width < MIN_WINDOW_WIDTH {
                width = MIN_WINDOW_WIDTH
            }
            if height < MIN_WINDOW_HEIGHT {
                height = MIN_WINDOW_HEIGHT
            }
            sdl.SetWindowSize(window, width, height)
            vulkan.recreate_swapchain(&vkctx, window)
            vkctx.framebuffer_resized = false
        }

        if vkctx.swapchain.extent.width == 0 || vkctx.swapchain.extent.height == 0 {
            continue
        }

        vulkan.draw_frame(&vkctx)
    }

    vulkan.cleanup(vkctx)
    sdl.DestroyWindow(window)
    sdl.Quit()
}