--!strict

-- Resolves runtime dependencies

local Root = script.Parent
local PackagesFolder = Root:FindFirstChild("Packages") or Root.Parent

local function resolveModule(name: string): ModuleScript
	local module = PackagesFolder:FindFirstChild(name)
	if not module or not module:IsA("ModuleScript") then
		error("GlassmorphicUI could not find required package: " .. name)
	end
	return module
end

return {
	EditableImageBlur = require(resolveModule("EditableImageBlur")),
	PixelColorApproximation = require(resolveModule("PixelColorApproximation")),
}
