--!strict
--!native
--!optimize 2

-- Liquid glass effects; pure buffer math with no Instances

local Types = require(script.Types)
local Refraction = require(script.Refraction)
local Warp = require(script.Warp)
local Geometry = require(script.Geometry)
local Reconstruct = require(script.Reconstruct)
local Heatmap = require(script.Heatmap)
local DebugOverlay = require(script.DebugOverlay)

export type LiquidParams = Types.LiquidParams
export type GeometryEntry = Types.GeometryEntry
export type ReconJob = Types.ReconJob

return {
	dispersionScales = Refraction.dispersionScales,

	warpKey = Warp.warpKey,
	buildWarp = Warp.buildWarp,

	geometryKey = Geometry.geometryKey,
	acquireGeometry = Geometry.acquireGeometry,
	releaseGeometry = Geometry.releaseGeometry,
	stepGeometry = Geometry.stepGeometry,

	clearColor = Reconstruct.clearColor,
	resampleGridBilinear = Reconstruct.resampleGridBilinear,
	reconstructRows = Reconstruct.reconstructRows,
	compositeRim = Reconstruct.compositeRim,

	renderDensityHeatmap = Heatmap.renderDensityHeatmap,

	drawContourOverlay = DebugOverlay.drawContourOverlay,
	drawNormalOverlay = DebugOverlay.drawNormalOverlay,
	drawCellCenterOverlay = DebugOverlay.drawCellCenterOverlay,
	renderGridView = DebugOverlay.renderGridView,
}
