# GlassmorphicUI

Glassmorphic UI in Roblox.

[Please consider supporting my work.](https://github.com/sponsors/boatbomber)

![image](https://github.com/boatbomber/GlassmorphicUI/assets/40185666/8db526c2-40e3-4936-9a66-91fa030ba0f4)

## Installation

Via [wally](https://wally.run):

```toml
[dependencies]
GlassmorphicUI = "boatbomber/glassmorphicui@0.6.0"
```

Alternatively, grab the `.rbxm` standalone model from the latest [release.](https://github.com/boatbomber/GlassmorphicUI/releases/latest)

## Usage

**Setting up glassy effects:**

You can add a `GlassmorphicUI` tag to a Frame or other GuiObject to automatically add a glassmorphic background to it.
Adding a `GlassmorphicUI` tag to an ImageLabel will apply the glass effects to it directly, instead of adding a background image.

Of course, you'll need to `require` the module in order for it to run even if you only use tags and don't intend to call any of its functions directly.

If you prefer to use the API directly instead of CollectionService tags, you can use the `GlassmorphicUI.new()` function to create a new glassy ImageLabel, `GlassmorphicUI.applyGlassToImageLabel()` to apply the glassmorphic effect to an existing ImageLabel, or `GlassmorphicUI.addGlassBackground()` to add a glassy background to an existing GuiObject. See the API section below for more details on those functions.

**Modifying the visuals:**

You can modify the glassmorphic effect by changing the `BackgroundTransparency` and `BackgroundColor3` properties of the ImageLabel. You can also use a `BlurRadius` attribute to modify the blur radius of the glassmorphic effect. It is compatible with UICorners and all other ImageLabel properties.

A higher `BackgroundTransparency` will make the glassmorphic effect more prominent as the blurry elements underneath become more visible. The `BackgroundColor3` will affect the tint of the glass. A lower `BlurRadius` will let you see more detail behind the glass. Be aware that a lower `BlurRadius` will make the imperfections of the approximated effect more obvious and ugly.

You can also use `GlassmorphicUI.setDefaultBlurRadius()` to set the default blur radius for all glassmorphic images. This will not affect images that have already been created.

## API

```Lua
function GlassmorphicUI.new(): ImageLabel
```

Returns an ImageLabel with a glassmorphic effect.

```lua
local GlassmorphicUI = require(Path.To.GlassmorphicUI)

local glassyimage = GlassmorphicUI.new()
glassyimage:SetAttribute("BlurRadius", 5)
glassyimage.BackgroundTransparency = 0.5
glassyimage.BackgroundColor3 = Color3.fromRGB(7, 48, 84)
glassyimage.Size = UDim2.fromScale(0.3, 0.3)
glassyimage.Position = UDim2.fromScale(0.5, 0.5)
glassyimage.AnchorPoint = Vector2.new(0.5, 0.5)
glassyimage.Parent = ScreenGui
```

```Lua
function GlassmorphicUI.applyGlassToImageLabel(ImageLabel: ImageLabel): ()
```

Takes an existing ImageLabel and applies the glassmorphic effect to it.
Useful for integrating GlassmorphicUI with existing UI systems.

```lua
local GlassmorphicUI = require(Path.To.GlassmorphicUI)

local glassyimage = Instance.new("ImageLabel")
glassyimage.BackgroundTransparency = 0.5
glassyimage.BackgroundColor3 = Color3.fromRGB(7, 48, 84)
glassyimage.Size = UDim2.fromScale(0.3, 0.3)
glassyimage.Position = UDim2.fromScale(0.5, 0.5)
glassyimage.AnchorPoint = Vector2.new(0.5, 0.5)
glassyimage.Parent = ScreenGui

GlassmorphicUI.applyGlassToImageLabel(glassyimage)
```

```Lua
function GlassmorphicUI.addGlassBackground(GuiObject: GuiObject): ImageLabel
```

Takes an existing GuiObject (such as a Frame) and parents a glassy ImageLabel inside it.
The ImageLabel will have a very low ZIndex as to appear as the background of the GuiObject.
The GuiObject will be forced to have a BackgroundTransparency of 1, otherwise the effect would just show your GuiObject's background behind the glass.
Useful for integrating GlassmorphicUI with existing UI systems.

```lua
local GlassmorphicUI = require(Path.To.GlassmorphicUI)

local frame = Instance.new("Frame")
frame.Size = UDim2.fromScale(0.2, 0.2)
frame.Parent = script.Parent

local glassyimage = GlassmorphicUI.addGlassBackground(frame)
glassyimage.BackgroundTransparency = 0.5
glassyimage.BackgroundColor3 = Color3.fromRGB(7, 48, 84)
```

```lua
function GlassmorphicUI.forceUpdate(ImageLabel: ImageLabel): ImageLabel
```

Forces a refresh of the glassmorphic effect on an ImageLabel. **Use sparingly, as this is an expensive operation.**
Intended to be used when you need an immediate and total update due to major background changes, such as closing a menu underneath the glass or teleporting the player to a new location.

```lua
function GlassmorphicUI.pauseUpdates(Window: ImageLabel): ImageLabel
```

Pauses updates to the glassmorphic effect on an ImageLabel. Useful for reducing lag when you have a lot of glassmorphic images that don't need to update every frame.

For example, if you have a glassmorphic effect on top of a background that never changes, you can just never update.

```lua
local glassyimage = GlassmorphicUI.pauseUpdates(GlassmorphicUI.new())
```

The initial update always happens, even if paused, so the glass won't be blank when created.

```lua
function GlassmorphicUI.resumeUpdates(Window: ImageLabel): ImageLabel
```

Resumes updates to the glassmorphic effect on an ImageLabel that has been paused by `GlassmorphicUI.pauseUpdates`.

```lua
function GlassmorphicUI.setDefaultBlurRadius(BlurRadius: number): ()
```

Sets the default blur radius for all glassmorphic images. Does not affect
images that have already been created.
