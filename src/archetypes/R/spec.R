# The archetype features: each one is numerator / denominator over the counts in season.R and tracked.R.
#
# side   offense or defense (the two are tabled and clustered separately)
# tier   season  = 293-game aggregates, every player in them
#        tracked = the ten games with tracking and events
# use    cluster = intended as a clustering input (tracked features must also pass the reliability screen)
#        context = how opponents treat the player; kept for description, not for clustering
#        check   = a tracked copy of something the season tier already measures
#        quality = data-quality column
# Per-chance and per-possession rates are scaled to "per 100".

SHOT_TYPES <- c("catch_and_shoot", "dribble_pull_up", "dunk", "floater", "heave", "hook", "layup", "leaner", "lob", "off_move",
                "post_fadeaway", "shake_and_raise", "stepback", "tip")
TYPED <- paste0("(", paste0("cst_", SHOT_TYPES, "_attempts", collapse = " + "), ")")
DRIBBLE_SPLIT <- "(cns_attempts + od_attempts)"
CONTEST_SPLIT <- "(cl_open_attempts + cl_light_attempts + cl_average_attempts + cl_plus_attempts)"
DRIVE_ENDS <- paste0("(", paste0("dr_end_type_", c("kickout", "pullout", "pullup", "interior_pass", "shot_near_basket"), "_count",
                                 collapse = " + "), ")")
HANDLER_COVERAGES <- paste0("(", paste0("handler_picks_vs_", c("blitz", "ice", "over", "switch", "under"), collapse = " + "), ")")
SCREENER_COVERAGES <- paste0("(", paste0("screener_picks_vs_", c("blitz", "ice", "show", "soft", "switch"), collapse = " + "), ")")

feature_spec <- function() {
  rows <- list()
  add <- function(feature, num, den, definition, use = "cluster", scale = 1) {
    rows[[length(rows) + 1L]] <<- data.table(feature = feature, num = num, den = den, scale = scale, use = use, definition = definition)
  }
  shot_share <- function(feature, cols, definition) add(feature, paste0("cst_", cols, "_attempts", collapse = " + "), TYPED, definition)

  # ---- offense, season: shot diet
  add("s_fga_per100", "attempts", "possessions", "Field goal attempts per 100 possessions on court", scale = 100)
  add("s_rim_share", "zone_restricted_area_attempts", "attempts", "Share of attempts in the restricted area")
  add("s_paint_share", "zone_paint_non_ra_attempts", "attempts", "Share of attempts in the paint outside the restricted area")
  add("s_mid_share", "zone_mid_range_attempts", "attempts", "Share of attempts from mid-range")
  add("s_corner3_share", "zone_corner_3_attempts", "attempts", "Share of attempts that are corner threes")
  add("s_ab3_share", "zone_above_break_3_attempts", "attempts", "Share of attempts that are above-the-break threes")
  add("s_cns_share", "cns_attempts", DRIBBLE_SPLIT, "Share of attempts that are catch-and-shoot (rest are off the dribble)")
  add("s_od3_share", "od_three_attempts", DRIBBLE_SPLIT, "Share of attempts that are off-the-dribble threes")
  shot_share("s_dunk_lob_share", c("dunk", "lob"), "Share of attempts that are dunks or lobs")
  shot_share("s_tip_share", "tip", "Share of attempts that are tips")
  shot_share("s_layup_share", "layup", "Share of attempts that are layups")
  shot_share("s_floater_share", "floater", "Share of attempts that are floaters")
  shot_share("s_post_shot_share", c("hook", "post_fadeaway"), "Share of attempts that are hooks or post fadeaways")
  shot_share("s_pullup_share", c("dribble_pull_up", "stepback", "shake_and_raise", "leaner"),
             "Share of attempts that are self-created jumpers (pull-up, stepback, shake-and-raise, leaner)")
  shot_share("s_offmove_share", "off_move", "Share of attempts that are jumpers off movement")
  add("s_contested_share", "cl_average_attempts + cl_plus_attempts", CONTEST_SPLIT,
      "Share of non-blocked attempts taken under an average or heavy contest")

  # ---- offense, season: drives
  add("s_drive_per100", "dr_total_drives", "possessions", "Drives per 100 possessions on court", scale = 100)
  for (k in c("pick", "handoff", "off_ball_screen", "iso", "closeout")) {
    add(paste0("s_drv_", sub("off_ball_screen", "obs", k), "_share"), paste0("dr_category_", k, "_count"), "dr_total_drives",
        paste("Share of drives that start from", c(pick = "an on-ball screen", handoff = "a handoff", off_ball_screen = "an off-ball screen",
                                                    iso = "an isolation", closeout = "attacking a closeout")[[k]]))
  }
  add("s_drv_kickout_share", "dr_end_type_kickout_count", DRIVE_ENDS, "Share of drives ending in a kick-out (turnovers and stoppages left out)")
  add("s_drv_pullup_share", "dr_end_type_pullup_count", DRIVE_ENDS, "Share of drives ending in a pull-up")
  add("s_drv_interior_share", "dr_end_type_interior_pass_count", DRIVE_ENDS, "Share of drives ending in an interior pass")
  add("s_drv_rim_share", "dr_end_type_shot_near_basket_count", DRIVE_ENDS, "Share of drives ending in a shot near the basket")
  add("s_drv_left_share", "dr_direction_left_count", "(dr_direction_left_count + dr_direction_right_count)", "Share of drives going left")
  add("s_drv_through_share", "dr_dribble_through_count", "dr_total_drives", "Share of drives dribbled through the key")

  # ---- offense, season: on-ball screens (the aggregates count direct picks only)
  add("s_pick_bh_per100", "handler_total_picks", "possessions", "Direct picks as ball handler per 100 possessions on court", scale = 100)
  add("s_pick_scr_per100", "screener_total_picks", "possessions", "Direct picks as screener per 100 possessions on court", scale = 100)
  add("s_bh_shoot_share", "handler_shot_taken", "handler_total_picks", "Share of direct picks as handler where he shoots")
  add("s_bh_pass_scr_share", "handler_pass_to_screener", "handler_total_picks", "Share of direct picks as handler where he passes to the screener")
  add("s_bh_shot3_share", "handler_score_3pt + handler_miss_3pt", "(handler_score + handler_miss)", "Share of his shots out of picks as handler that are threes")
  add("s_bh_middle_share", "handler_picks_at_middle", "handler_total_picks", "Share of direct picks as handler set in the middle of the floor")
  add("s_scr_shoot_share", "screener_shot_taken", "screener_total_picks", "Share of direct picks as screener where he shoots")
  add("s_scr_shot3_share", "screener_score_3pt + screener_miss_3pt", "(screener_score + screener_miss)",
      "Share of his shots out of picks as screener that are threes (pop rather than roll)")
  add("s_ctx_bh_under_share", "handler_picks_vs_under", HANDLER_COVERAGES, "Share of direct picks as handler where his defender goes under", "context")
  add("s_ctx_bh_switch_share", "handler_picks_vs_switch", HANDLER_COVERAGES, "Share of direct picks as handler that are switched", "context")
  add("s_ctx_scr_soft_share", "screener_picks_vs_soft", SCREENER_COVERAGES, "Share of direct picks as screener where his defender drops", "context")
  add("s_ctx_scr_switch_share", "screener_picks_vs_switch", SCREENER_COVERAGES, "Share of direct picks as screener that are switched", "context")

  # ---- offense, tracked: touches
  add("t_touch_per100", "touches", "off_ch", "Touches per 100 offensive chances on court", scale = 100)
  add("t_drib_per_touch", "touch_drib", "touches", "Dribbles per touch")
  add("t_sec_per_touch", "touch_secs", "touches", "Seconds per touch")
  add("t_zero_drib_share", "touch_zero", "touches", "Share of touches with no dribble")
  add("t_ball_time_share", "touch_secs", "off_secs", "Share of his team's on-court offensive clock time with the ball in his hands")
  add("t_initiate_share", "init", "off_ch_bc", "Share of chances (second chances excluded) where he has the ball when it first reaches the frontcourt")
  add("t_catch_dist", "touch_fc_dist", "touch_fc", "Feet from the hoop where his frontcourt touches start")
  add("t_catch_paint_share", "touch_z_paint", "touch_fc", "Share of frontcourt touches starting in the paint")
  add("t_catch_corner_share", "touch_z_corner", "touch_fc", "Share of frontcourt touches starting in a corner beyond the arc")
  add("t_catch_top_share", "touch_z_top", "touch_fc", "Share of frontcourt touches starting at the top beyond the arc")
  add("t_shot_per_touch", "touch_shot", "touches", "Share of touches that end in his shot")
  add("t_pass_per_touch", "touch_pass", "touches", "Share of touches that end in a pass")
  add("t_pass_len", "pass_len", "passes", "Feet per completed pass")
  add("t_pass_inside_share", "pass_inside", "passes", "Share of completed passes received in the key or restricted area")
  add("t_pass_kickout_share", "pass_kickout", "passes", "Share of completed passes thrown from the key to beyond the arc")
  add("t_pass_to_shot_share", "pass_to_shot", "passes", "Share of completed passes whose receiver shoots on that touch (make or miss)")

  # ---- offense, tracked: screens set and used
  add("t_pick_scr_per100", "pick_scr", "off_ch", "On-ball screens set per 100 chances (all picks)", "check", 100)
  add("t_pick_bh_per100", "pick_bh", "off_ch", "On-ball screens used as handler per 100 chances (all picks)", "check", 100)
  add("t_obs_scr_per100", "obs_scr", "off_ch", "Off-ball screens set per 100 chances", scale = 100)
  add("t_obs_cut_per100", "obs_cut", "off_ch", "Off-ball screens used as cutter per 100 chances", scale = 100)
  add("t_ho_set_per100", "ho_set", "off_ch", "Handoffs given per 100 chances", scale = 100)
  add("t_ho_recv_per100", "ho_recv", "off_ch", "Handoffs received per 100 chances", scale = 100)
  add("t_roll_share", "pick_roll", "pick_scr_trk", "Share of on-ball screens after which he rolls (10 ft from the hoop, or 6 ft closer, 2.5 s later)")
  add("t_pop_share", "pick_pop", "pick_scr_trk", "Share of on-ball screens after which he pops (no roll and 20+ ft from the hoop 2.5 s later)")
  add("t_obs_touch_share", "obs_cut_touch", "obs_cut", "Share of off-ball screens used that lead to his touch within 4 s")
  add("t_obs_shot_share", "obs_cut_shot", "obs_cut", "Share of off-ball screens used that lead to his shot within 6 s")
  add("t_obs_rim_share", "obs_cut_rim", "obs_cut_trk", "Share of off-ball screens used after which he cuts to the rim (within 2 s)")
  add("t_shot_off_screen_share", "shot_off_screen", "shots", "Share of his shots released within 4 s of using an off-ball screen or handoff")

  # ---- offense, tracked: other actions
  add("t_iso_per100", "iso", "off_ch", "Isolations per 100 chances", scale = 100)
  add("t_post_per100", "post", "off_ch", "Post-ups per 100 chances", scale = 100)
  add("t_cut_per100", "cuts", "off_ch", "Cuts to the rim per 100 chances (off the ball 18+ ft out, within 8 ft 2 s later; rolls excluded)", scale = 100)
  add("t_co_faced_per100", "co_faced", "off_ch", "Closeouts faced per 100 chances", scale = 100)
  add("t_co_shot_share", "co_shot", "co_faced", "Share of closeouts faced that he shoots over")
  add("t_co_drive_share", "co_drive", "co_faced", "Share of closeouts faced that he drives against")

  # ---- offense, tracked: movement
  add("t_shot_speed_3", "shot_three_speed", "shot_three_trk", "Shooter speed at release on threes, ft/s")
  add("t_shot_speed_mid", "shot_mid_speed", "shot_mid_trk", "Shooter speed at release on twos from beyond 6 ft, ft/s")
  add("t_shot_speed_rim", "shot_rim_speed", "shot_rim_trk", "Shooter speed at release on twos within 6 ft, ft/s")
  add("t_precatch_speed_3", "cns3_pre_speed", "cns3_trk", "Speed over the second before the catch on catch-and-shoot threes, ft/s")
  for (z in c("corner", "wing", "top", "mid", "dunker", "paint")) {
    add(paste0("t_off_", z, "_share"), paste0("offb_", z), "offb_n", paste("Share of off-ball half-court time spent in:", z))
  }
  add("t_off_still_share", "offb_still", "offb_n", "Share of off-ball half-court time moving slower than 2 ft/s")
  add("t_off_speed", "offb_speed", "offb_n", "Mean speed off the ball in the half court, ft/s")
  add("t_off_hoop_dist", "offb_dist", "offb_n", "Mean distance from the hoop off the ball in the half court, ft")
  add("t_trans_rank", "trans_rank", "trans_n", "Mean order of arrival in the frontcourt after a defensive rebound or live turnover (1 = first)")
  add("t_crash_share", "glass_crash", "glass_n", "Share of teammates' shots where he is on the glass when the ball reaches the rim")
  add("t_getback_share", "glass_back", "glass_n", "Share of teammates' shots where he retreats 3+ ft between release and rim")
  add("t_three_share", "shot_three", "shots", "Share of recorded shots that are threes (tracked games)", "check")
  add("t_drive_per100", "drives", "off_ch", "Drives per 100 chances (tracked games)", "check", 100)
  add("t_off_det_share", "offb_det", "offb_n", "Share of his off-ball positions that are detected rather than extrapolated", "quality")

  # ---- defense, tracked: position and assignment
  add("d_onball_share", "dfr_on", "(dfr_on + dfr_offb)", "Share of assigned half-court time in which his man has the ball")
  add("d_onball_gap", "dfr_on_gap", "dfr_on", "Feet from his man when his man has the ball")
  add("d_offball_gap", "dfr_offb_gap", "dfr_offb", "Feet from his man when his man is off the ball")
  add("d_help_share", "dfr_help", "dfr_offb", "Share of off-ball time spent 8+ ft from his man")
  add("d_paint_share", "dfr_paint", "dfr_n", "Share of half-court defensive time in the paint")
  add("d_far_share", "dfr_far", "dfr_n", "Share of half-court defensive time 18+ ft from the hoop")
  add("d_hoop_dist", "dfr_dist", "dfr_n", "Mean distance from the hoop on defense in the half court, ft")
  add("d_last_line_share", "dfr_last", "dfr_n", "Share of half-court defensive time as the defender nearest the hoop")
  add("d_man_hoop_dist", "dfr_man_dist", "dfr_man_n", "Mean distance from the hoop of the man he is assigned, ft")
  add("d_speed", "dfr_speed", "dfr_n", "Mean speed on defense in the half court, ft/s")
  add("d_meet_dist", "d_meet_dist", "d_meet_n", "Feet from the hoop where he first gets within 8 ft of the ball handler he is guarding")
  add("d_switch_per100", "d_mu_switch", "d_mu_ch", "Changes of assignment per 100 chances", scale = 100)

  # ---- defense, tracked: actions defended
  add("d_pick_bh_per100", "d_pick_bh", "def_ch", "On-ball screens defended as the handler's defender per 100 chances", scale = 100)
  add("d_pick_scr_per100", "d_pick_scr", "def_ch", "On-ball screens defended as the screener's defender per 100 chances", scale = 100)
  add("d_scr_soft_share", "d_scr_soft", "d_scr_cov", "As screener's defender: share of coverages that are soft (drop)")
  add("d_scr_show_share", "d_scr_show + d_scr_blitz", "d_scr_cov", "As screener's defender: share of coverages that are show or blitz")
  add("d_scr_switch_share", "d_scr_switch", "d_scr_cov", "As screener's defender: share of coverages that are switches")
  add("d_scr_depth", "d_scr_depth", "d_scr_depth_n", "As screener's defender: feet nearer the hoop than the screener when the screen is set")
  add("d_bh_under_share", "d_bh_under", "d_bh_cov", "As handler's defender: share of screens he goes under")
  add("d_bh_switch_share", "d_bh_switch", "d_bh_cov", "As handler's defender: share of screens switched")
  add("d_chase_per100", "d_obs_cut + d_ho_recv", "def_ch", "Off-ball screens and handoffs defended as the cutter's or receiver's defender per 100 chances", scale = 100)
  add("d_obs_scr_per100", "d_obs_scr", "def_ch", "Off-ball screens defended as the screener's defender per 100 chances", scale = 100)
  add("d_closeout_per100", "d_co", "def_ch", "Closeouts made per 100 chances", scale = 100)
  add("d_closeout_dist", "d_co_dist", "d_co_dist_n", "Feet from the receiver at the catch on his closeouts")
  add("d_iso_per100", "d_iso", "def_ch", "Isolations defended per 100 chances", scale = 100)
  add("d_post_per100", "d_post", "def_ch", "Post-ups defended per 100 chances", scale = 100)
  add("d_drive_per100", "d_drive", "def_ch", "Drives defended as the driver's defender per 100 chances", scale = 100)
  add("d_drive_help_share", "d_drive_help", "d_drive_other", "Share of other men's drives where he closes 4+ ft to end within 6 ft of the driver")
  add("d_rim_contest_per100", "d_shot_rim", "def_ch", "Shots within 6 ft where he is the nearest defender, per 100 chances", scale = 100)
  add("d_three_contest_per100", "d_shot_three", "def_ch", "Threes where he is the nearest defender, per 100 chances", scale = 100)
  add("d_glass_crash_share", "d_glass_crash", "d_glass_n", "Share of opponent shots where he is on the glass when the ball reaches the rim")
  add("d_glass_leak_share", "d_glass_leak", "d_glass_n", "Share of opponent shots where he moves 3+ ft away from the hoop between release and rim")

  # ---- defense, tracked: who he guards (assignment-time-weighted profile of his men; see guard_counts)
  add("d_guard_touch", "g_touch", "g_frames", "Touches per 100 chances of the men he is assigned, weighted by time")
  add("d_guard_three", "g_three", "g_frames", "Season three-point share of the men he is assigned, weighted by time")
  add("d_guard_screener", "g_screener", "g_frames", "Season direct picks as screener per 100 possessions of the men he is assigned")
  add("d_guard_handler", "g_handler", "g_frames", "Season direct picks as handler per 100 possessions of the men he is assigned")
  add("d_det_share", "dfr_det", "dfr_n", "Share of his defensive positions that are detected rather than extrapolated", "quality")

  spec <- rbindlist(rows)
  spec[, side := fifelse(startsWith(feature, "d_"), "defense", "offense")]
  spec[, tier := fifelse(startsWith(feature, "s_"), "season", "tracked")]
  if (anyDuplicated(spec$feature)) stop("Duplicate feature names in the spec")
  spec[]
}
