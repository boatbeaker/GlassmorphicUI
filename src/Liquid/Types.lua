--!strict

-- Shared types for Liquid modules

export type LiquidParams = {
	cornerRadius: number, -- px
	superEllipseFactor: number, -- corner exponent; 2 is circle, higher is squarer
	thickness: number, -- slab depth and refracting band width in px
	refractionFactor: number, -- refractive index ratio, 1 = no refraction
	chromaticAberration: number, -- per-channel displacement spread, 0-1, 0 disables
	fresnelSize: number, -- px reach of the rim fresnel, 0 disables
	fresnelHardness: number, -- 0-1
	fresnelIntensity: number, -- 0-1, recon-time not baked
	glareSize: number, -- px reach of the rim glare, 0 disables
	glareHardness: number, -- 0-1
	glareIntensity: number, -- 0-1.2
	glareConvergence: number, -- 0-1; how tightly the glare hugs its axis
	glareOppositeSide: number, -- 0-1 strength of the second lobe
	glareAngle: number, -- radians
	maxOutputResolution: number, -- max axis of the output EditableImage
}

export type GeometryEntry = {
	Key: string,
	Refs: number,
	Ready: boolean,
	WinW: number, -- window px
	WinH: number,
	OutW: number, -- output image px
	OutH: number,
	StepX: number, -- window px per output px
	StepY: number,
	DispMap: buffer, -- interleaved i16 pairs per pixel
	AuxMap: buffer, -- u8 fresnel, u8 glare, u8 alpha, one unused pad byte per pixel
	Phase: number, -- 1 = geometry stage 1, 2 = stage 2, 3 = done
	Row: number, -- next row for the current phase
	Params: LiquidParams,
	RawField: boolean, -- debug flag for raw distance field
}

export type ReconJob = {
	Out: buffer, -- output RGBA, OutW x OutH
	Disp: buffer,
	Aux: buffer,
	Grid: buffer, -- source grid RGBA, GridW x GridH
	GridW: number,
	GridH: number,
	OutW: number,
	OutH: number,
	StepX: number, -- window px per output px
	StepY: number,
	WarpX: buffer, -- per-grid-row window-x to grid-column LUTs
	WarpY: buffer, -- window-y -> grid-row LUT
	TintR: number, -- 0-1
	TintG: number,
	TintB: number,
	TintAlpha: number, -- 0-1, tint mix weight against backdrop
	RedScale: number, -- dispersion multiplier; green is 1
	BlueScale: number,
	BlurSigma: number, -- frost sigma in output px
	FresnelIntensity: number, -- rim composite weight
	RimEnabled: boolean, -- true when rim fresnel or glare enabled
	BilinearFetch: boolean?, -- debug flag
	Row: number, -- next row to reconstruct
	RowEnd: number, -- exclusive end row
}

return {}
