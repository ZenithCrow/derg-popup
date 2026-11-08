const std = @import("std");
const time = std.time;
const build_options = @import("build_options");

const c = @import("c");

const anim = @import("anim/anim.zig");
const raster = @import("anim/raster.zig");

const time_buf_size = 8;

const title = "derg battery popup";
const font_path = build_options.assets_path ++ "/fonts/PressStart2P-Regular-extended.ttf";
const derg_frame_path = build_options.assets_path ++ "/derg-frames/";

const icon_size: f32 = 120;
const font_size: f32 = 56;

const bg_color: c.SDL_Color = .{
    .r = 0x22,
    .g = 0x22,
    .b = 0x22,
    .a = 0x88,
};

const fg_color: c.SDL_Color = .{
    .r = 0xdd,
    .g = 0xdd,
    .b = 0xdd,
    .a = 0xff,
};

const trans_color: c.SDL_Color = .{
    .r = 0,
    .g = 0,
    .b = 0,
    .a = 0,
};

const text_padding = 64;

const neg_top_offset_rel: f32 = 0;
const neg_left_offset_rel: f32 = 0;
const neg_bottom_offset_rel: f32 = @as(f32, 1) / 8.0;
const neg_right_offset_rel: f32 = @as(f32, 1) / 8.0;

const neg_top_offset_icon: f32 = icon_size * neg_top_offset_rel;
const neg_left_offset_icon: f32 = icon_size * neg_left_offset_rel;
const neg_bottom_offset_icon: f32 = icon_size * 0;
const neg_right_offset_icon: f32 = icon_size * neg_right_offset_rel;

const neg_top_offset_text: f32 = font_size * neg_top_offset_rel;
const neg_left_offset_text: f32 = font_size * neg_left_offset_rel;
const neg_bottom_offset_text: f32 = font_size * neg_bottom_offset_rel;
const neg_right_offset_text: f32 = font_size * neg_right_offset_rel;

const derg_floor_y_offset = 41;
const derg_upper_clip_offset = 5;
const derg_w = 120;
const derg_scale = 4;
const window_anim_y_offset = 300;
const window_y_offset = (derg_floor_y_offset - derg_upper_clip_offset) * derg_scale;

const border_radius = 20;

const anim_pause_ms: u64 = 2000;

var rndr: ?*c.SDL_Renderer = null;
var win: ?*c.SDL_Window = null;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var exe_dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir_path_len = try std.process.executableDirPath(io, &exe_dir_path_buf);
    const exe_dir_path = exe_dir_path_buf[0..exe_dir_path_len];
    std.process.setCurrentPath(io, exe_dir_path) catch |err| {
        std.log.err("failed to set current path to '{s}': {t}", .{ exe_dir_path, err });
        return error.SetCurrentPathFailed;
    };

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.log.err("failed to initialize SDL: {s}", .{c.SDL_GetError()});
        return error.SDLInitFailed;
    }
    defer c.SDL_Quit();

    if (!c.TTF_Init()) {
        std.log.err("failed to initialize SDL_ttf: {s}", .{c.SDL_GetError()});
        return error.TTFInitFailed;
    }
    defer c.TTF_Quit();

    var secs: c_int = undefined;
    var perc: c_int = undefined;
    const power_state = c.SDL_GetPowerInfo(&secs, &perc);
    if (power_state == c.SDL_POWERSTATE_ERROR) {
        std.log.err("failed to get power state: {s},", .{c.SDL_GetError()});
        return error.GetPowerStateFailed;
    }

    var bat_icon_buf: [3]u8 = undefined;
    var bat_icon_w = std.Io.Writer.fixed(&bat_icon_buf);
    var display_bat_info = false;

    switch (power_state) {
        c.SDL_POWERSTATE_CHARGED => bat_icon_w.writeAll(&.{ 0x5a, 0x46, 0x4a }) catch unreachable,
        c.SDL_POWERSTATE_CHARGING => {
            bat_icon_w.writeByte(0x5a) catch unreachable;
            display_bat_info = true;
        },
        c.SDL_POWERSTATE_NO_BATTERY => bat_icon_w.writeByte(0x5a) catch unreachable,
        c.SDL_POWERSTATE_ON_BATTERY => display_bat_info = true,
        c.SDL_POWERSTATE_UNKNOWN => {
            bat_icon_w.writeByte('-') catch unreachable;
            display_bat_info = true;
        },
        else => unreachable,
    }

    var bat_perc_buf: [5]u8 = undefined;
    var bat_perc_w = std.Io.Writer.fixed(&bat_perc_buf);

    var bat_min_buf: [10]u8 = undefined;
    var bat_min_w = std.Io.Writer.fixed(&bat_min_buf);

    if (display_bat_info) {
        if (perc == -1) {
            bat_perc_w.writeAll("?%") catch unreachable;
        } else {
            const num_segs = 8;
            const segment: u8 = @truncate(@as(u32, @bitCast(perc)) * num_segs / 100);

            bat_icon_w.writeByte(0x41 + if (segment > 5) 5 else segment) catch unreachable;
            bat_icon_w.writeByte(0x47 + if (segment < 5) 0 else segment - 5) catch unreachable;
            bat_perc_w.print("{d} %", .{perc}) catch unreachable;
        }

        if (secs == -1) {
            bat_min_w.writeAll("- min") catch unreachable;
        } else {
            bat_min_w.print("{d} min", .{@as(u32, @bitCast(secs)) / 60}) catch unreachable;
        }
    }

    const bat_icon_str: []const u8 = bat_icon_w.buffered();
    var bat_perc_str: []const u8 = bat_perc_w.buffered();
    var bat_min_str: []const u8 = bat_min_w.buffered();

    if (bat_perc_str.len == 0)
        bat_perc_str = " ";

    if (bat_min_str.len == 0)
        bat_min_str = " ";

    const icon_font = c.TTF_OpenFont(font_path, icon_size);
    if (icon_font == null) {
        std.log.err("failed to load icon font: {s}", .{c.SDL_GetError()});
        return error.FontLoadFailed;
    }
    defer c.TTF_CloseFont(icon_font);

    const bat_icon_surf = c.TTF_RenderText_Blended(
        icon_font,
        bat_icon_str.ptr,
        bat_icon_str.len,
        fg_color,
    );
    if (bat_icon_surf == null) {
        std.log.err("failed to render battery icons: {s}", .{c.SDL_GetError()});
        return error.TextRenderFailed;
    }

    const text_font = c.TTF_OpenFont(font_path, font_size);
    if (icon_font == null) {
        std.log.err("failed to load font: {s}", .{c.SDL_GetError()});
        return error.FontLoadFailed;
    }
    defer c.TTF_CloseFont(text_font);

    const bat_perc_surf = c.TTF_RenderText_Blended(
        text_font,
        bat_perc_str.ptr,
        bat_perc_str.len,
        fg_color,
    );
    if (bat_perc_surf == null) {
        std.log.err("failed to render text: {s}", .{c.SDL_GetError()});
        return error.TextRenderFailed;
    }

    const bat_min_surf = c.TTF_RenderText_Blended(
        text_font,
        bat_min_str.ptr,
        bat_min_str.len,
        fg_color,
    );
    if (bat_min_surf == null) {
        std.log.err("failed to render text: {s}", .{c.SDL_GetError()});
        return error.TextRenderFailed;
    }

    var disp_count: c_int = undefined;
    const disps = c.SDL_GetDisplays(&disp_count);
    if (disps == null or disp_count < 1) {
        std.log.err("failed to get displays: {s}", .{c.SDL_GetError()});
        return error.DisplayGetFailed;
    }

    const disp_mode = c.SDL_GetCurrentDisplayMode(disps[0]);
    if (disp_mode == null) {
        std.log.err("failed to get display mode: {s}", .{c.SDL_GetError()});
        return error.DisplayModeGetFailed;
    }

    const r_text_w = @max(bat_perc_surf.*.w, bat_min_surf.*.w);
    var win_w = bat_icon_surf.*.w + 2 * text_padding - @as(c_int, @intFromFloat(neg_left_offset_icon + neg_right_offset_icon));
    if (display_bat_info)
        win_w += r_text_w + text_padding;

    const floating_win_h = bat_icon_surf.*.h + 2 * text_padding - @as(c_int, @intFromFloat(neg_top_offset_icon + neg_bottom_offset_icon));
    const win_h = floating_win_h + window_anim_y_offset + window_y_offset;

    c.SDL_DestroySurface(bat_icon_surf);
    c.SDL_DestroySurface(bat_perc_surf);
    c.SDL_DestroySurface(bat_min_surf);

    if (!c.SDL_CreateWindowAndRenderer(
        title,
        win_w,
        win_h,
        c.SDL_WINDOW_BORDERLESS | c.SDL_WINDOW_TRANSPARENT | c.SDL_WINDOW_NOT_FOCUSABLE | c.SDL_WINDOW_ALWAYS_ON_TOP | c.SDL_WINDOW_UTILITY,
        &win,
        &rndr,
    )) {
        std.log.err("failed to create window and renderer: {s}", .{c.SDL_GetError()});
        return error.WindowAndRendererCreationFailed;
    }
    defer {
        c.SDL_DestroyRenderer(rndr);
        c.SDL_DestroyWindow(win);
    }

    const center_x = @divTrunc(disp_mode.*.w - win_w, 2);
    const center_y = @divTrunc(disp_mode.*.h - floating_win_h, 2) - window_y_offset;

    _ = c.SDL_SetWindowPosition(win, center_x, center_y);

    const easing: anim.ExpoEasing = .{ .anim_dur_s = 1, .scale_px = 1 };
    var window_frame_iter: anim.FrameIterator(anim.ExpoEasing) = .init(easing);
    var anim_end = false;
    var window_anim_first_part = true;
    var window_y_frame: c_int = undefined;
    var window_frame_dir: f32 = undefined;
    var window_anim_dir: c_int = undefined;
    var window_anim_paused: bool = false;
    var window_anim_pause_timeout: anim.TickTimeout = .{ .timeout_ms = 2000 };

    var window_frame_lim: anim.FrameLimiter = .{ .frame_rate = easing.anim_frame_rate, .last_tick = 0 };

    var derg_anim_iter: anim.ImgAnimIterator(16, derg_frame_path, 3, ".png") = .init(rndr);
    defer derg_anim_iter.deinit();

    var derg_frame_lim: anim.FrameLimiter = .{ .frame_rate = 8, .last_tick = 0 };
    var derg_frame_tex: ?*c.SDL_Texture = null;
    var derg_y_frame: c_int = undefined;

    var event: c.SDL_Event = undefined;
    var running = true;

    while (running and !anim_end) {
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                else => {},
            }
        }

        c.SDL_Delay(2);

        var redraw = false;
        const ticks = c.SDL_GetTicks();

        if (window_anim_paused and window_anim_pause_timeout.isTimeoutTick(ticks))
            window_anim_paused = false;

        if (window_frame_lim.isFrameTick(ticks) and !window_anim_paused) {
            redraw = true;

            if (!window_anim_first_part and window_frame_iter.step > window_frame_iter.total_steps)
                anim_end = true;

            if (window_frame_iter.next()) |window_frame| {
                window_anim_dir = if (window_anim_first_part) 1 else -1;
                window_frame_dir = if (window_anim_first_part) (1 - window_frame) else window_frame;

                if (window_anim_first_part) {
                    derg_y_frame = window_anim_dir * @as(c_int, @intFromFloat(window_anim_y_offset * (1 - window_frame_dir)));
                    window_y_frame = derg_y_frame + window_y_offset;
                }
            } else if (window_anim_first_part) {
                window_anim_first_part = false;
                window_anim_paused = true;
                window_anim_pause_timeout.start(ticks);
                window_frame_iter.step = 0;
            } else anim_end = true;
        }
        if (derg_frame_lim.isFrameTick(ticks)) {
            redraw = true;

            derg_frame_tex = try derg_anim_iter.next();
            _ = c.SDL_SetTextureScaleMode(derg_frame_tex, c.SDL_SCALEMODE_NEAREST);
        }

        if (redraw) {
            _ = c.SDL_SetRenderDrawColor(rndr, 0, 0, 0, 0);
            _ = c.SDL_RenderClear(rndr);

            _ = c.SDL_SetRenderDrawColor(
                rndr,
                @intFromFloat(window_frame_dir * bg_color.r),
                @intFromFloat(window_frame_dir * bg_color.g),
                @intFromFloat(window_frame_dir * bg_color.b),
                @intFromFloat(window_frame_dir * bg_color.a),
            );

            const back_rect: c.SDL_FRect = .{
                .x = 0,
                .y = @floatFromInt(window_y_frame),
                .w = @floatFromInt(win_w),
                .h = @floatFromInt(floating_win_h),
            };
            _ = c.SDL_RenderFillRect(rndr, &back_rect);

            const fg_color_frame: c.SDL_Color = .{
                .r = @intFromFloat(window_frame_dir * fg_color.r),
                .g = @intFromFloat(window_frame_dir * fg_color.g),
                .b = @intFromFloat(window_frame_dir * fg_color.b),
                .a = @intFromFloat(window_frame_dir * fg_color.a),
            };

            const bat_icon_tex = try transTexFromText(bat_icon_str, icon_font, fg_color_frame, rndr);
            defer c.SDL_DestroyTexture(bat_icon_tex);

            const bat_icon_src_rect: c.SDL_FRect = .{
                .x = neg_left_offset_icon,
                .y = neg_top_offset_icon,
                .w = @as(f32, @floatFromInt(bat_icon_tex.*.w)) - (neg_left_offset_icon + neg_right_offset_icon),
                .h = @as(f32, @floatFromInt(bat_icon_tex.*.h)) - (neg_top_offset_icon + neg_bottom_offset_icon),
            };

            const bat_icon_dst_rect: c.SDL_FRect = .{
                .x = text_padding,
                .y = @as(f32, @floatFromInt(window_y_frame)) + text_padding,
                .w = bat_icon_src_rect.w,
                .h = bat_icon_src_rect.h,
            };

            _ = c.SDL_RenderTexture(rndr, bat_icon_tex, &bat_icon_src_rect, &bat_icon_dst_rect);

            if (display_bat_info) {
                const bat_perc_tex = try transTexFromText(bat_perc_str, text_font, fg_color_frame, rndr);
                defer c.SDL_DestroyTexture(bat_perc_tex);

                const bat_perc_src_rect: c.SDL_FRect = .{
                    .x = neg_left_offset_text,
                    .y = neg_top_offset_text,
                    .w = @as(f32, @floatFromInt(bat_perc_tex.*.w)) - (neg_left_offset_text + neg_right_offset_text),
                    .h = @as(f32, @floatFromInt(bat_perc_tex.*.h)) - (neg_top_offset_text + neg_bottom_offset_text),
                };

                const bat_perc_dst_rect: c.SDL_FRect = .{
                    .x = bat_icon_dst_rect.x + bat_icon_dst_rect.w + text_padding,
                    .y = bat_icon_dst_rect.y - font_size / 8,
                    .w = bat_perc_src_rect.w,
                    .h = bat_perc_src_rect.h,
                };

                _ = c.SDL_RenderTexture(rndr, bat_perc_tex, &bat_perc_src_rect, &bat_perc_dst_rect);

                const bat_min_tex = try transTexFromText(bat_min_str, text_font, fg_color_frame, rndr);
                defer c.SDL_DestroyTexture(bat_min_tex);

                const bat_min_src_rect: c.SDL_FRect = .{
                    .x = neg_left_offset_text,
                    .y = neg_top_offset_text,
                    .w = @as(f32, @floatFromInt(bat_min_tex.*.w)) - (neg_left_offset_text + neg_right_offset_text),
                    .h = @as(f32, @floatFromInt(bat_min_tex.*.h)) - (neg_top_offset_text + neg_bottom_offset_text),
                };

                const bat_min_dst_rect: c.SDL_FRect = .{
                    .x = bat_perc_dst_rect.x,
                    .y = bat_icon_dst_rect.y + bat_icon_dst_rect.h - bat_min_src_rect.h + font_size / 8,
                    .w = bat_min_src_rect.w,
                    .h = bat_min_src_rect.h,
                };

                _ = c.SDL_RenderTexture(rndr, bat_min_tex, &bat_min_src_rect, &bat_min_dst_rect);
            }

            raster.renderFillOuterQCircle(rndr, .{ .x = win_w - border_radius - 1, .y = window_y_frame + border_radius - 1 }, border_radius, 1, trans_color);
            raster.renderFillOuterQCircle(rndr, .{ .x = border_radius, .y = window_y_frame + border_radius - 1 }, border_radius, 2, trans_color);
            raster.renderFillOuterQCircle(rndr, .{ .x = border_radius, .y = window_y_frame + floating_win_h - border_radius }, border_radius, 3, trans_color);
            raster.renderFillOuterQCircle(rndr, .{ .x = win_w - border_radius - 1, .y = window_y_frame + floating_win_h - border_radius }, border_radius, 4, trans_color);

            if (derg_frame_tex) |tex| {
                _ = c.SDL_SetTextureAlphaModFloat(tex, window_frame_dir);

                const derg_dest: c.SDL_FRect = .{
                    .x = @floatFromInt(@divTrunc((win_w - derg_w * derg_scale), 2)),
                    .y = @floatFromInt(-derg_upper_clip_offset * derg_scale + derg_y_frame),
                    .w = @as(f32, @floatFromInt(tex.w)) * derg_scale,
                    .h = @as(f32, @floatFromInt(tex.h)) * derg_scale,
                };

                _ = c.SDL_RenderTexture(rndr, tex, null, &derg_dest);
            }

            _ = c.SDL_RenderPresent(rndr);
        }
    }
}

fn transTexFromText(text: []const u8, font: ?*c.TTF_Font, color: c.SDL_Color, r: ?*c.SDL_Renderer) !*c.SDL_Texture {
    const surf = c.TTF_RenderText_Blended(
        font,
        text.ptr,
        text.len,
        color,
    );
    if (surf == null) {
        std.log.err("failed to render battery icons: {s}", .{c.SDL_GetError()});
        return error.TextRenderFailed;
    }
    defer c.SDL_DestroySurface(surf);

    const details = c.SDL_GetPixelFormatDetails(surf.*.format);
    const key = c.SDL_MapRGBA(details, null, 0, 0, 0, 0);
    _ = c.SDL_SetSurfaceColorKey(surf, true, key);

    const bat_icon_tex = c.SDL_CreateTextureFromSurface(r, surf);
    if (bat_icon_tex == null) {
        std.log.err("failed to create texture from surface: {s}", .{c.SDL_GetError()});
        return error.TextureCreateFailed;
    }

    return bat_icon_tex;
}
