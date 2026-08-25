--!strict

-- Tunables and attribute defaults; read at use time, not copied

local Config = {}

Config.TAG_NAME = "GlassmorphicUI"

Config.SAMPLING_CELL_SIZE = 5 -- screen px per grid cell; sampling cost scales with area
Config.SAMPLE_TIME_BUDGET = 5e-3 -- per-frame budget for PCA sampling
Config.LIQUID_TIME_BUDGET = 8e-3 -- per-frame budget for geometry + reconstruction
Config.TEMPORAL_SMOOTHING = 0.6
Config.RESIZE_DEBOUNCE = 1 / 25
Config.RESIZE_MAX_WAIT = 1 / 10 -- layout interval for never-settling tweens
Config.MIN_OUTPUT_RESOLUTION = 32 -- floor of the step-down ladder
Config.EDGE_DENSITY_BOOST = 3 -- edge density multiplier; refracted fetches concentrate there
Config.DEBUG_SAMPLING_HEATMAP = false -- render sampler density instead of glass

-- Debug views; see Liquid/DebugOverlay.lua. Grid views show source grid instead of finished glass
Config.DEBUG_OVERLAY = nil :: string? -- "sdf-contours" | "melt-contours" | "normals" | "cell-centers" | "cell-centers-uniform" | "grid-view" | "grid-view-flat"
Config.DEBUG_RAW_DISTANCE_FIELD = false -- use raw distance field depth and normal
Config.DEBUG_FROST_NO_PREMULTIPLY = false -- frost without coverage premultiply, showing tint bleed
Config.DEBUG_UNIFORM_WARP = false -- flat density warp to show rim smears demand warp removes
Config.DEBUG_BILINEAR_FETCH = false -- bilinear grid fetch to show cell lattice (set ChromaticAberration 0)
Config.DEBUG_FROST_NEAREST_LEVEL = false -- single blur call to show plateaus and pops

-- Parallel reconstruction; phases run inside frame, split across workers in chunks
Config.PARALLEL_ENABLED = true
Config.PARALLEL_WORKER_COUNT = 8
Config.PARALLEL_MIN_OUTPUT_PIXELS = 72 * 72 -- message copies cost more than pass below this
Config.PARALLEL_CHUNK_PIXELS = 64 * 1024 -- output px per worker per frame
Config.PARALLEL_TIMEOUT_FRAMES = 300 -- ~5s before in-flight pass counts as lost
Config.PARALLEL_RESIZE_SETTLE = 0.25 -- relayout settle time before passes scatter again
Config.FROST_WORKER_COUNT = 3 -- EditableImageBlur.BlurAsync workers for the parallel route's frost

-- Defaults when window sets no attribute; length attributes are UDims on UICorner convention
-- resolved px = offset + scale * the window's min axis.
Config.DEFAULT_CORNER_RADIUS = UDim.new(0.4, 0) -- used when no UICorner or attribute supplies a radius
Config.DEFAULT_SUPER_ELLIPSE_FACTOR = 3 -- corner exponent; 2 is a circle, higher is squarer
Config.DEFAULT_THICKNESS = UDim.new(0.15, 0) -- depth of the refracting band
Config.DEFAULT_REFRACTION_FACTOR = 2.1
Config.DEFAULT_CHROMATIC_ABERRATION = 0.2 -- per-channel displacement spread; red fetches this fraction farther, blue this fraction shorter
Config.DEFAULT_FRESNEL_SIZE = UDim.new(0.1, 0)
Config.DEFAULT_FRESNEL_HARDNESS = 40
Config.DEFAULT_FRESNEL_INTENSITY = 25
Config.DEFAULT_GLARE_SIZE = UDim.new(0.2, 0)
Config.DEFAULT_GLARE_HARDNESS = 40
Config.DEFAULT_GLARE_INTENSITY = 70
Config.DEFAULT_GLARE_CONVERGENCE = 90
Config.DEFAULT_GLARE_OPPOSITE_SIDE = 50
Config.DEFAULT_GLARE_ANGLE = -50 -- degrees
Config.DEFAULT_BLUR_RADIUS = UDim.new(0.06, 0) -- the gaussian sigma is a third of the resolved px
Config.DEFAULT_MAX_OUTPUT_RESOLUTION = 1024 -- max axis of the output image

-- Below this sigma (output px) the frost pass is skipped as imperceptible
Config.MIN_BLUR_SIGMA = 0.1

Config.BLUR_RADIUS_ATTRIBUTE_NAME = "BlurRadius"
Config.TRANSPARENCY_ATTRIBUTE_NAME = "Transparency"

-- Attributes that shape the glass. Any change re-derives the layout; a
-- geometry key change also starts a chunked map rebuild.
Config.LIQUID_PARAM_ATTRIBUTES = {
	"CornerRadius",
	"SuperEllipseFactor",
	"Thickness",
	"RefractionFactor",
	"ChromaticAberration",
	"FresnelSize",
	"FresnelHardness",
	"FresnelIntensity",
	"GlareSize",
	"GlareHardness",
	"GlareIntensity",
	"GlareConvergence",
	"GlareOppositeSide",
	"GlareAngle",
	"MaxOutputResolution",
}

return Config
