-- Interactive playground with cycling backgrounds, glass widget, and control panel

local GlassmorphicUI = require(script.GlassmorphicUI)
local Controls = require(script.Controls)
local Widgets = require(script.Widgets)

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "GlassmorphicUIDemo"
ScreenGui.DisplayOrder = 999999
ScreenGui.IgnoreGuiInset = true
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent = script.Parent

-- Backdrop images for testing
local backgroundIds = {
	"rbxassetid://16606410725",
	"rbxassetid://98714845496735",
	"rbxassetid://124714689502718",
	"rbxassetid://18808456782",
	"rbxassetid://16029056896",
}
local backgroundIndex = 1

local background = Instance.new("ImageLabel")
background.Name = "Background"
background.Size = UDim2.fromScale(1, 1)
background.Image = backgroundIds[backgroundIndex]
background.ZIndex = 0
background.Parent = ScreenGui

local controls = Controls.create(ScreenGui)

-- Live pipeline readouts for active widget
local readouts = Controls.createReadouts(ScreenGui)
local setGridLine = readouts.line("Sample Grid")
local setOutputLine = readouts.line("Output")
local setScaleLine = readouts.line("Output Px Per Cell")
local setSamplesLine = readouts.line("Samples This Frame")
local setWritesLine = readouts.line("Grid Writes Since Recon")
local setFramesLine = readouts.line("Frames Since Recon")
local setRouteLine = readouts.line("Recon Route")

type Widget = { window: Frame, uiCorner: UICorner }

local activeWidget: Widget? = nil
local widgetIndex = 1
-- Switching resets every control to
-- New widget renders with builder values or library defaults
local widgetResets: { (widget: Widget) -> () } = {}

-- Apply control edits to active widget
local function setWidgetAttribute(attribute: string): (value: any) -> ()
	return function(value)
		if activeWidget then
			activeWidget.window:SetAttribute(attribute, value)
		end
	end
end

-- Reset control handle to window value without firing callback
local function resetToAttribute(handle: { set: (value: any) -> () }, attribute: string, default: any)
	table.insert(widgetResets, function(widget)
		handle.set(widget.window:GetAttribute(attribute) or default)
	end)
end

local function attributeSlider(
	label: string,
	attribute: string,
	min: number,
	max: number,
	default: number,
	step: number
)
	resetToAttribute(controls.slider(label, min, max, default, step, setWidgetAttribute(attribute)), attribute, default)
end

local function attributeUDimInput(label: string, attribute: string, default: UDim)
	resetToAttribute(controls.udimInput(label, default, setWidgetAttribute(attribute)), attribute, default)
end

local setWidget -- forward-declared; needs the sizing controls built below
local switchButton = controls.button("Widget: " .. Widgets.list[1].name, function()
	setWidget(widgetIndex % #Widgets.list + 1)
end)

controls.button("Cycle Background", function()
	backgroundIndex = backgroundIndex % #backgroundIds + 1
	background.Image = backgroundIds[backgroundIndex]
end)

-- Panel shows library defaults for untouched windows
attributeUDimInput("Thickness", "Thickness", GlassmorphicUI.DEFAULT_THICKNESS)
attributeSlider("Refraction Factor", "RefractionFactor", 1, 4, GlassmorphicUI.DEFAULT_REFRACTION_FACTOR, 0.01)
attributeSlider("Chromatic Aberration", "ChromaticAberration", 0, 1, GlassmorphicUI.DEFAULT_CHROMATIC_ABERRATION, 0.01)
attributeUDimInput("Fresnel Size", "FresnelSize", GlassmorphicUI.DEFAULT_FRESNEL_SIZE)
attributeSlider("Fresnel Hardness", "FresnelHardness", 0, 100, GlassmorphicUI.DEFAULT_FRESNEL_HARDNESS, 1)
attributeSlider("Fresnel Intensity", "FresnelIntensity", 0, 100, GlassmorphicUI.DEFAULT_FRESNEL_INTENSITY, 1)
attributeUDimInput("Glare Size", "GlareSize", GlassmorphicUI.DEFAULT_GLARE_SIZE)
attributeSlider("Glare Hardness", "GlareHardness", 0, 100, GlassmorphicUI.DEFAULT_GLARE_HARDNESS, 1)
attributeSlider("Glare Intensity", "GlareIntensity", 0, 120, GlassmorphicUI.DEFAULT_GLARE_INTENSITY, 1)
attributeSlider("Glare Convergence", "GlareConvergence", 0, 100, GlassmorphicUI.DEFAULT_GLARE_CONVERGENCE, 1)
attributeSlider("Glare Opposite Side", "GlareOppositeSide", 0, 100, GlassmorphicUI.DEFAULT_GLARE_OPPOSITE_SIDE, 1)
attributeSlider("Glare Angle", "GlareAngle", -180, 180, GlassmorphicUI.DEFAULT_GLARE_ANGLE, 1)
attributeUDimInput("Blur Radius", "BlurRadius", GlassmorphicUI.DEFAULT_BLUR_RADIUS)
attributeSlider("Transparency", "Transparency", 0, 1, 1, 0.01)
-- Drive widget UICorner; default replaced on first widget switch
local cornerInput = controls.udimInput("Corner Radius", UDim.new(), function(value)
	if activeWidget then
		activeWidget.uiCorner.CornerRadius = value
	end
end)
attributeSlider("Superellipse Factor", "SuperEllipseFactor", 2, 7, GlassmorphicUI.DEFAULT_SUPER_ELLIPSE_FACTOR, 0.1)

-- Size and corner controls reset from widget's created shape
local widthSlider = controls.slider("Widget Width", 140, 400, 140, 10, function(value)
	if activeWidget then
		local window = activeWidget.window
		window.Size = UDim2.fromOffset(value, window.Size.Y.Offset)
	end
end)
local heightSlider = controls.slider("Widget Height", 60, 260, 60, 10, function(value)
	if activeWidget then
		local window = activeWidget.window
		window.Size = UDim2.fromOffset(window.Size.X.Offset, value)
	end
end)
table.insert(widgetResets, function(widget)
	local size = widget.window.Size
	widthSlider.set(size.X.Offset)
	heightSlider.set(size.Y.Offset)
	cornerInput.set(widget.uiCorner.CornerRadius)
end)

local moving = true
local function movingPosition(): UDim2
	local x = (math.cos(os.clock() * 0.4) / 4) + 0.4
	local y = (math.sin(os.clock() * 0.4) / 4) + 0.5
	return UDim2.fromScale(x, y)
end

-- Swap widgets: start fresh at defaults, reset panel controls
function setWidget(index: number)
	widgetIndex = index
	local entry = Widgets.list[index]
	if activeWidget then
		activeWidget.window:Destroy()
	end
	local widget = entry.create(ScreenGui)
	if moving then
		-- Same frame as creation to skip default position mid-orbit
		widget.window.Position = movingPosition()
	end
	for _, reset in widgetResets do
		reset(widget)
	end
	switchButton.setText("Widget: " .. entry.name)
	activeWidget = widget
end
setWidget(1)

controls.checkbox("Move In A Circle", moving, function(checked)
	moving = checked
end)

-- Debug toggles flip Config flags and force widget rebuild
local Config = require(script.GlassmorphicUI.Config)

local function refreshActiveWidget()
	if activeWidget then
		GlassmorphicUI.forceUpdate(activeWidget.window)
	end
end

-- false represents "overlay off"; arrays cannot hold nil
local overlayModes = {
	false,
	"sdf-contours",
	"melt-contours",
	"normals",
	"cell-centers",
	"cell-centers-uniform",
	"grid-view",
	"grid-view-flat",
}
local overlayIndex = 1
local overlayButton
overlayButton = controls.button("Debug Overlay: none", function()
	overlayIndex = overlayIndex % #overlayModes + 1
	local mode = overlayModes[overlayIndex]
	Config.DEBUG_OVERLAY = if mode then mode else nil
	overlayButton.setText("Debug Overlay: " .. (if mode then mode else "none"))
	refreshActiveWidget()
end)

controls.checkbox("Debug: Density Heatmap", Config.DEBUG_SAMPLING_HEATMAP, function(checked)
	Config.DEBUG_SAMPLING_HEATMAP = checked
	refreshActiveWidget()
end)
controls.checkbox("Debug: Raw Distance Field", Config.DEBUG_RAW_DISTANCE_FIELD, function(checked)
	Config.DEBUG_RAW_DISTANCE_FIELD = checked
	refreshActiveWidget()
end)
controls.checkbox("Debug: Frost Without Premultiply", Config.DEBUG_FROST_NO_PREMULTIPLY, function(checked)
	Config.DEBUG_FROST_NO_PREMULTIPLY = checked
	refreshActiveWidget()
end)
controls.checkbox("Debug: Uniform Warp Grid", Config.DEBUG_UNIFORM_WARP, function(checked)
	Config.DEBUG_UNIFORM_WARP = checked
	refreshActiveWidget()
end)
controls.checkbox("Debug: Bilinear Fetch", Config.DEBUG_BILINEAR_FETCH, function(checked)
	Config.DEBUG_BILINEAR_FETCH = checked
	refreshActiveWidget()
end)
controls.checkbox("Debug: Frost Nearest Level", Config.DEBUG_FROST_NEAREST_LEVEL, function(checked)
	Config.DEBUG_FROST_NEAREST_LEVEL = checked
	refreshActiveWidget()
end)

local function updateReadouts()
	local stats = if activeWidget then GlassmorphicUI.getDebugStats(activeWidget.window) else nil
	if not stats then
		return
	end
	local grid, output = stats.GridResolution, stats.OutputResolution
	local gridCells = grid.X * grid.Y
	local outputPixels = output.X * output.Y
	setGridLine(string.format("%dx%d = %d", grid.X, grid.Y, gridCells))
	setOutputLine(string.format("%dx%d = %d", output.X, output.Y, outputPixels))
	setScaleLine(string.format("%.1f", if gridCells > 0 then outputPixels / gridCells else 0))
	setSamplesLine(tostring(stats.SamplesLastFrame))
	setWritesLine(tostring(stats.GridWritesSinceRecon))
	setFramesLine(tostring(stats.FramesSinceRecon))
	setRouteLine(stats.ReconRoute)
end

task.spawn(function()
	while true do
		if moving and activeWidget then
			activeWidget.window.Position = movingPosition()
		end
		updateReadouts()
		task.wait()
	end
end)
