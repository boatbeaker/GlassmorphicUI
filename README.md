# GlassmorphicUI

Glassmorphic UI in Roblox.

[Please consider supporting my work.](https://github.com/sponsors/boatbomber)

<https://github.com/user-attachments/assets/85dd0678-88fb-4f9a-a8f6-0a4e2091502f>

Read all about how this works:

<a href="https://www.boatbomber.com/blog/liquid-glass">
  <img width="1280" height="716" alt="cover" src="https://github.com/user-attachments/assets/5613bee7-4afe-4c14-823a-fc84233a5737" />
</a>

You can also try out the playground place: https://www.roblox.com/games/75587637914653/GlassmorphicUI-Playground

https://github.com/user-attachments/assets/e35049a1-64d7-408b-9571-307fc07db3a7

## Installation

Via [wally](https://wally.run):

```toml
[dependencies]
GlassmorphicUI = "boatbomber/glassmorphicui@1.0.0"
```

Alternatively, grab the `.rbxm` standalone model from the latest [release.](https://github.com/boatbeaker/GlassmorphicUI/releases/latest)

## Usage

Add a `GlassmorphicUI` tag to any GuiObject to add a glass background. The library inserts a `GlassPane` ImageLabel below other children.

Require the module to start it, even if you only use tags.

Use the API directly: `GlassmorphicUI.new()` creates a new glass window, and `GlassmorphicUI.addGlassBackground()` adds glass to an existing GuiObject.

## Controls

Everything is driven by attributes on the window. A wrongly typed attribute is ignored and will use the default.

`BackgroundColor3` controls the tint hue, so no attribute needed for that.

| Attribute | Default | Range | Meaning |
|---|---|---|---|
| `Thickness` | `(0.15, 0)` | UDim, resolved 1px–min axis | Depth of the refracting band. Sets both how far the lensing reaches inward and how strongly it bends |
| `RefractionFactor` | `2.1` | 1–4 | Refractive index ratio. `1` disables refraction |
| `ChromaticAberration` | `0.2` | 0–1 | Per-channel displacement spread that fringes the band with color: at `0.2`, red fetches 20% farther and blue 20% shorter than green. `0` disables it |
| `CornerRadius` | `(0.8, 0)` | UDim, resolved 0–min axis | Curvature of the corners. Sets the shape of the window |
| `SuperEllipseFactor` | `3` | 2–7 | Corner exponent. `2` is a circular corner, higher is squarer |
| `FresnelSize` | `(0.1, 0)` | UDim, resolved 0–min axis | Reach of the rim brightening. Zero disables it |
| `FresnelHardness` | `40` | 0–100 | How abruptly the rim brightening cuts off |
| `FresnelIntensity` | `25` | 0–100 | Strength of the rim brightening |
| `GlareSize` | `(0.2, 0)` | UDim, resolved 0–min axis | Reach of the rim glints. Zero disables them |
| `GlareHardness` | `40` | 0–100 | How abruptly the glints cut off across the band |
| `GlareIntensity` | `70` | 0–120 | Strength of the glints |
| `GlareConvergence` | `90` | 0–100 | How tightly the glints hug the glare axis |
| `GlareOppositeSide` | `50` | 0–100 | Strength of the second glint, opposite the first |
| `GlareAngle` | `-50` | ±180 | Glare axis direction, in degrees |
| `BlurRadius` | `(0.06, 0)` | UDim, resolved 1px–min axis | Frost radius, blurring the refracted backdrop beneath the rim shading; the gaussian sigma is a third of it. 1px is effectively unblurred |
| `Transparency` | seeded | 0–1 | Tint alpha. 0 renders fully opaque and skips backdrop sampling entirely. |
| `MaxOutputResolution` | `1024` | 16–1024 | Max axis of the output image. Lower this on memory-constrained devices |

When EditableImage memory runs out, the window halves its resolution down to 32 and logs a warning.

## API

```Lua
function GlassmorphicUI.new(): Frame
```

Returns a Frame with a glass background pane inside it.

```lua
local GlassmorphicUI = require(Path.To.GlassmorphicUI)

local glassWindow = GlassmorphicUI.new()
glassWindow:SetAttribute("Thickness", UDim.new(0, 40))
glassWindow:SetAttribute("Transparency", 0.5)
glassWindow.BackgroundColor3 = Color3.fromRGB(7, 48, 84)
glassWindow.Size = UDim2.fromScale(0.3, 0.3)
glassWindow.Position = UDim2.fromScale(0.5, 0.5)
glassWindow.AnchorPoint = Vector2.new(0.5, 0.5)
glassWindow.Parent = ScreenGui
```

```Lua
function GlassmorphicUI.addGlassBackground(GuiObject: GuiObject): GuiObject
```

Tags an existing GuiObject and returns it. Use this to add glass to UI built by another system.

```lua
local GlassmorphicUI = require(Path.To.GlassmorphicUI)

local frame = Instance.new("Frame")
frame.Size = UDim2.fromScale(0.2, 0.2)
frame.Parent = script.Parent

GlassmorphicUI.addGlassBackground(frame)
-- Set tint alpha with the attribute. BackgroundTransparency has no effect here.
frame:SetAttribute("Transparency", 0.5)
frame.BackgroundColor3 = Color3.fromRGB(7, 48, 84)
```

```Lua
function GlassmorphicUI.applyGlassToImageLabel(ImageLabel: ImageLabel): ()
```

Tags an existing ImageLabel. Equivalent to `addGlassBackground` but kept for compatibility. The glass renders above the label's `Image`.

```lua
function GlassmorphicUI.forceUpdate(Window: GuiObject): GuiObject
```

Rebuilds the glass completely: geometry, sampling, and reconstruction in one frame. This is synchronous; use it only for major background changes like closing an overlay or teleporting.

```lua
function GlassmorphicUI.pauseUpdates(Window: GuiObject): GuiObject
```

Pauses updates to the glass on a window. Use this for windows with static backdrops, and call `forceUpdate` when needed.

```lua
local glassWindow = GlassmorphicUI.pauseUpdates(GlassmorphicUI.new())
```

The first update runs even if paused, so the glass renders initially.

```lua
function GlassmorphicUI.resumeUpdates(Window: GuiObject): GuiObject
```

Resumes updates to a paused window.

```lua
function GlassmorphicUI.setDefaultBlurRadius(BlurRadius: UDim): ()
```

Sets the default frost radius as a UDim. Windows without a `BlurRadius` attribute inherit this default at their next layout. The minimum resolved radius is 1px (effectively unblurred).

```lua
function GlassmorphicUI.getDebugStats(Window: GuiObject): DebugStats?
```

Returns pipeline stats: grid and output resolutions, backdrop samples received, frames since last reconstruction, and execution path (`"parallel"`, `"sync"`, or `"idle"`). Returns nil if the window has no glass. Allocates a fresh table per call, so poll once per frame at most.
