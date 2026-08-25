--!strict
--!native
--!optimize 2

-- Per-window state record, constructor, and registry of live objects

local Liquid = require(script.Parent.Liquid)

-- One worker's output-row band, drip-fed in chunks to avoid long phases
export type ParallelWorkerState = {
	Actor: Actor,
	Slot: number, -- results key this worker's chunk strings land under
	RowNext: number, -- next absolute row expected back from this worker
	RowEnd: number, -- exclusive end of this worker's band
	AwaitingRows: number, -- rows in the chunk currently in flight; 0 once the band is done
}

-- One in-flight banded pass; record is the cancellation token
export type ParallelPending = {
	PassId: number,
	Job: Liquid.ReconJob, -- Job.Out gathers the bands; the finish stages then read the job on the main thread
	Results: SharedTable, -- workers write chunk strings into per-band slots here
	Workers: { ParallelWorkerState },
	FramesWaited: number, -- frames since any chunk arrived, for the timeout
}

export type GlassObject = {
	Window: GuiObject,
	Pane: ImageLabel, -- library-owned child; not clipped by window UICorner so full mask shows
	EditableImage: EditableImage?,
	WarnedImageCreateFailure: boolean,
	Initialized: boolean, -- window has been parented and configured
	Parented: boolean, -- mirrors Window.Parent to skip per-pixel Instance reads
	Pixels: buffer, -- u8 RGBA grid accumulator, row-major
	Scratch: buffer, -- grid snapshot for reconstruction
	PixelCount: number,
	PixelIndex: number, -- 0-based byte offset into Pixels
	Resolution: Vector2, -- source-grid resolution
	ResolutionX: number, -- Resolution.X as plain number for hot path
	-- Grid cells concentrate density where refracted fetches land
	GridPosX: buffer?, -- f32 per grid cell, x center in window coordinates (each row has its own warp)
	GridPosY: buffer?, -- f32 per grid row, y center
	WarpLutX: buffer?, -- per-row window-x to grid-column lookup tables
	WarpLutY: buffer?, -- window-y to grid-row lookup table
	WarpKey: string?, -- input signature of the built warp; skips rebuilds when unchanged
	WindowPositionX: number,
	WindowPositionY: number,
	WindowColor: { number },
	BlurRadius: number, -- resolved px, converted to output-px sigma by frost
	Paused: boolean,
	LiquidParams: Liquid.LiquidParams?,
	Geometry: Liquid.GeometryEntry?,
	OutputResolution: Vector2,
	OutPixels: buffer?, -- u8 RGBA reconstruction target
	OutBlend: buffer?, -- base-level blur copy the frost's level mix reads from
	ReconJob: Liquid.ReconJob?, -- non-nil while a synchronous reconstruction pass is in flight
	ParallelJob: ParallelPending?, -- non-nil while the worker pool runs this window's pass
	ParallelId: number, -- the window's identity in worker-side caches; 0 until the first scatter
	MapsGeneration: number, -- bumped when the warp or geometry maps rebuild; workers cache the maps keyed by it
	FinishToken: {}?, -- identity token for the in-flight finish thread; clearing it cancels a stale finish before it uploads
	ForceRecon: boolean,
	GridWritesSinceRecon: number,
	FramesSinceRecon: number,
	SamplesLastFrame: number, -- backdrop samples this window got last frame, for the debug stats
	PendingLayout: boolean, -- a layout change is being debounced
	LastLayoutRequestClock: number,
	FirstLayoutRequestClock: number, -- when the pending debounce began
	LadderCap: number, -- resolution cap imposed by the step-down ladder
	UICornerConnection: RBXScriptConnection?,
	Connections: { RBXScriptConnection }, -- disconnected when the window is removed
}

local GlassObject = {}

-- Every live, unpaused glass object, iterated round-robin by the scheduler
GlassObject.list = {} :: { GlassObject }
-- Weak keys, so an abandoned window can garbage-collect with its object
GlassObject.byWindow = setmetatable({} :: { [GuiObject]: GlassObject }, { __mode = "k" })

function GlassObject.addToUpdateList(glassObject: GlassObject)
	if not table.find(GlassObject.list, glassObject) then
		table.insert(GlassObject.list, glassObject)
	end
end

function GlassObject.removeFromUpdateList(glassObject: GlassObject)
	local index = table.find(GlassObject.list, glassObject)
	if index then
		table.remove(GlassObject.list, index)
	end
end

-- At full tint alpha no backdrop can show through, so the pipeline
-- short-circuits: no sampling, no grid snapshot, no frost.
function GlassObject.isOpaque(glassObject: GlassObject): boolean
	return glassObject.WindowColor[4] >= 1
end

function GlassObject.create(Window: GuiObject): GlassObject
	-- Start with a 1x1 window-color pixel; the first layout resamples it
	-- into the real grid. clearColor packs the RGB; the seed is opaque.
	local windowColor = Window.BackgroundColor3
	local initialPixels = buffer.create(4)
	buffer.writeu32(initialPixels, 0, Liquid.clearColor(windowColor.R, windowColor.G, windowColor.B) + 0xFF000000)

	-- The pane carries the glass image as a child of the window (see the
	-- GlassObject type for why the window cannot carry it itself)
	local pane = Instance.new("ImageLabel")
	pane.Name = "GlassPane"
	pane.Size = UDim2.fromScale(1, 1)
	pane.BackgroundTransparency = 1
	pane.BorderSizePixel = 0
	pane.ZIndex = -999999
	pane.Parent = Window

	local glassObject = {
		Window = Window,
		Pane = pane,
		EditableImage = nil :: EditableImage?,
		WarnedImageCreateFailure = false,
		Initialized = false,
		Parented = Window.Parent ~= nil,
		Pixels = initialPixels,
		Scratch = buffer.create(4),
		PixelCount = 1,
		PixelIndex = 0,
		Resolution = Vector2.one,
		ResolutionX = 1,
		GridPosX = nil :: buffer?,
		GridPosY = nil :: buffer?,
		WarpLutX = nil :: buffer?,
		WarpLutY = nil :: buffer?,
		WarpKey = nil :: string?,
		WindowPositionX = 0,
		WindowPositionY = 0,
		WindowColor = {
			windowColor.R,
			windowColor.G,
			windowColor.B,
			1 - Window.BackgroundTransparency,
		},
		BlurRadius = 1, -- resolved px; Attributes.updateWindowBlur refreshes it once the window has a size
		Paused = false,
		LiquidParams = nil :: Liquid.LiquidParams?,
		Geometry = nil :: Liquid.GeometryEntry?,
		OutputResolution = Vector2.zero,
		OutPixels = nil :: buffer?,
		OutBlend = nil :: buffer?,
		ReconJob = nil :: Liquid.ReconJob?,
		ParallelJob = nil :: ParallelPending?,
		ParallelId = 0,
		MapsGeneration = 0,
		FinishToken = nil :: {}?,
		ForceRecon = false,
		GridWritesSinceRecon = 0,
		FramesSinceRecon = 0,
		SamplesLastFrame = 0,
		PendingLayout = false,
		LastLayoutRequestClock = 0,
		FirstLayoutRequestClock = 0,
		LadderCap = math.huge,
		UICornerConnection = nil :: RBXScriptConnection?,
		Connections = {} :: { RBXScriptConnection },
	}
	GlassObject.byWindow[Window] = glassObject
	return glassObject
end

return GlassObject
