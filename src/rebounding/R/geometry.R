# Court, basket and ball geometry for the rebounding models, in feet, offense attacking the hoop at +x
# (tracking rotated 180 degrees with possessions.leftHoop, as everywhere else in this repository).
# FIBA dimensions are given in metres and converted once here.

FT_PER_M <- 3.28084
COURT_HALF_L <- 14 * FT_PER_M            # 45.93 ft
COURT_HALF_W <- 7.5 * FT_PER_M           # 24.61 ft
RIM_X <- (14 - 1.575) * FT_PER_M         # hoop centre, 40.76 ft from centre court
RIM_Z <- 3.05 * FT_PER_M                 # 10.01 ft
RIM_R <- 0.225 * FT_PER_M                # inner radius of the ring, 0.74 ft
RIM_TUBE <- 0.009 * FT_PER_M             # radius of the ring's metal, 0.03 ft
BOARD_X <- (14 - 1.2) * FT_PER_M         # front face of the backboard, 41.99 ft
BOARD_HALF_W <- 0.9 * FT_PER_M           # 2.95 ft
BOARD_Z0 <- 2.90 * FT_PER_M              # lower edge, 9.51 ft
BOARD_Z1 <- 3.95 * FT_PER_M              # upper edge, 12.96 ft
BALL_R <- 0.122 * FT_PER_M               # size 7 ball, 0.40 ft
GRAVITY <- 32.174                        # ft/s^2
FPS <- 25

#' Horizontal distance from the hoop centre.
hoop_dist <- function(x, y) sqrt((x - RIM_X)^2 + y^2)

#' TRUE where a horizontal position is outside the court's lines.
out_of_court <- function(x, y) abs(x) > COURT_HALF_L | abs(y) > COURT_HALF_W
