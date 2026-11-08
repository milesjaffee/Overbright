# Overbright

An open-source menu bar app that unlocks the extra brightness Apple reserves for HDR
content on Liquid Retina XDR and Pro Display XDR panels — and, on the same slider, takes
the screen darker than macOS will let you go.

One control, from "darker than the lowest notch" through "exactly what macOS does" to
"as bright as the panel can actually sustain."

MIT licensed. No private APIs. No kernel extensions. No gamma tables.

---

## What it does

MacBook Pro (14" and 16", M1 Pro and later) and Pro Display XDR panels can hit around
1600 nits in a highlight and sustain roughly 1000 nits across the whole screen. macOS
normally caps SDR content — that is, everything except HDR video — at about 500 nits, and
only opens the rest of the range when something on screen is genuinely HDR.

Overbright puts a transparent full-screen layer over your desktop that is registered as
HDR content and composites with a **multiply** blend. The panel opens its extended range
because there is real EDR content on screen, and every pixel underneath gets multiplied by
your chosen gain. Multiply is the important part: `black × 2.0` is still black, so
contrast and colour survive. Overlays that paint white over the screen instead of
multiplying are what produce the washed-out, milky look people complain about.

Below 1.0× the same layer multiplies *down*, which needs no EDR at all. That half of the
slider works on any Mac — Airs, Minis with third-party monitors, Intel machines — because
it is just arithmetic in the compositor.

## Emergency quit

If the overlay obscures the menu bar, press **Command-Option-Control-Escape**
(**⌘⌥⌃Esc**) to quit Overbright immediately and remove its overlays.

## What it does not do

- **No gamma tables.** See the note below; this is a deliberate architectural choice.
- **No private frameworks.** Nothing from `DisplayServices`, `CoreDisplay` or IOKit
  brightness internals.
- **Nothing to clean up.** All state is two windows per display. Windows die with the
  process, so a crash, a force quit or a Mac that panics leaves your display exactly as
  it was.

---

## The problems in existing tools, and what this does about them

Everything below is a real, documented complaint about a shipping XDR brightness app —
mostly drawn from BrightIntosh's release notes and issue tracker, BrightXDR's stated
limitations, and Apple's own developer forums.

### Flickering and pulsing

**The reported symptom.** The screen visibly pumps between two brightness levels,
sometimes slowly, sometimes rapidly. BrightIntosh shipped v5.4.4 specifically titled
"Reduces screen flickering", whose fix was a higher poll rate for the HDR headroom value.

**What is actually going on.** `NSScreen.maximumExtendedDynamicRangeColorComponentValue`
is not a constant. It is the ratio between the panel's peak luminance and the *current*
SDR white point, so it moves when you press a brightness key, when the ambient light
sensor moves the backlight, when the panel throttles for heat, and when another app puts
HDR content on screen. A naive implementation reads that number and sets its gain from it
every frame — which means the gain is a function of a value that is itself partly a
function of the gain. That is a feedback loop, and feedback loops oscillate.

**Four separate fixes here, because it has four separate causes.**

1. **A fixed EDR anchor.** A single pixel in the corner of each display permanently
    requests the panel's full potential headroom, independent of the gain being applied.
  Because the anchor sits below the full-screen gain layer, its input is inversely
  compensated so its final displayed value—and therefore its headroom request—stays
  fixed as the slider moves. (`Overlay.swift`, `DisplayOverlay`)

2. **Median filtering.** Headroom samples go through a 5-sample median rather than an
   average. A median throws away one-frame spikes entirely without adding the lag that
   an averaging filter would. (`Log.swift`, `SampleWindow`)

3. **Asymmetric slew limiting with hysteresis.** Gain never steps; it ramps, at 1.6 stops
   per second going up and 3.0 going down, in log space so the ramp is perceptually even.
   A *drop* in the reported ceiling additionally has to persist for 450 ms before it is
   acted on, because macOS briefly dips the reported headroom during Space switches and
   brightness-key presses. (`BrightnessEngine.swift`, `slew` and `usableCeiling`)

4. **An adaptive poll rate that goes the other way.** Rather than polling fast all the
   time, this polls at display rate *while the gain is moving* and drops to 8 Hz once it
   has settled. With a slew limiter in front of it, 125 ms of latency on a headroom change
   is invisible, and the idle rate is the difference between a rounding error and a
   measurable battery cost.

### Overexposure and blown highlights

**The reported symptom.** BrightIntosh v5.4.3 was "Fix overexposure look" and v5.4.5
"Fixing over exposure". Vivid's own release notes mention "an issue where for some users
the colors were saturated".

**Fix.** Two things. Multiply compositing rather than additive/over compositing, so the
gain is a true exposure change rather than a white veil. And a headroom reserve — 12% by
default — so the top of the range is never driven right up against the reported limit,
where anything that is already near white clips.

### It gets bright and then sags a few seconds later

**The reported symptom.** Brightness that ramps up nicely and then visibly fades.

**Cause.** The peak number and the sustained number are different. Apple rates these
panels at 1600 nits peak but 1000 nits sustained across the full screen — Vivid's
developers say explicitly that they target 1000 rather than 1600 for this reason. If you
aim at the peak figure across the entire display, the panel accepts it and then protects
itself, and you watch it back down.

**Fix.** A sustained-luminance cap, defaulting to 62.5% of potential headroom
(1000 ÷ 1600). It is exposed in the advanced settings for anyone who wants to trade
stability for a brighter screen. (`Settings.sustainedFraction`)

### It stops working after closing and reopening the lid

**The reported symptom.** Common enough that at least one alternative
(`levelsio/xdr-boost`) exists specifically to fix this bug in Vivid. Vivid's own
changelog includes "Fix for reduced brightness after your screen locked and unlocked",
and BrightIntosh has shipped "improves brightness reliability after system sleep",
"recovered after browsing Time Machine Backups", and "reliability when waking your Mac,
opening the lid, or changing displays" as separate releases.

**Cause.** The overlay window survives these transitions but the EDR grant attached to it
does not, and there is no notification for "your EDR grant was revoked". The window is
still there, still on top, still apparently working — and the panel has quietly gone back
to its SDR ceiling.

**Fix.** Treat every state transition as suspect and rebuild rather than trying to detect
the specific failure. `SystemWatcher.swift` listens for system sleep and wake, display
sleep and wake, lock and unlock, screen saver start and stop, fast user switching, screen
parameter changes, and CoreGraphics display reconfiguration. Both the AppKit notification
and the lower-level CG callback are wired up, because during a clamshell transition the
AppKit one is coalesced and sometimes arrives late. Recovery is debounced so a burst of
notifications from one physical event produces one rebuild, and every rebuild ramps the
gain back up from 1.0 rather than snapping.

### White flashes in Mission Control, washed-out screenshots

**The reported symptom.** BrightXDR lists both as known limitations: HDR brightness drops
while switching Spaces, and a white screen can appear in desktop and Space thumbnails.
Screenshots and screen recordings coming out wrong is a related complaint.

**Fix.** `NSWindow.sharingType = .none` excludes the overlay from screen capture
entirely, which covers screenshots, QuickTime, Mission Control thumbnails and
screen-sharing in one go. The window collection behaviour includes `.canJoinAllSpaces`,
`.stationary` and `.transient` so it neither gets torn down nor slides around during a
Space switch, and the active-space notification triggers a re-assert rather than a full
rebuild, which would be visible.

### Conflicts with f.lux, Night Shift, Lunar, BetterDisplay

**The reported symptom.** BrightIntosh's README states plainly that it and f.lux will
likely not work simultaneously. Version 6.0.0 was largely about warning users when a
conflicting app is running, and 5.4.6 was about resetting colours on sleep.

**Cause.** Those tools all write the display gamma table via `CGSetDisplayTransferByTable`.
It is a single global resource with no arbitration — last writer wins, and each app
periodically notices its ramp is gone and stomps it back.

**Fix.** Overbright does not use gamma at all, for either direction of the slider. It
never touches that resource, so there is nothing to conflict over. Run f.lux, Night Shift
and Overbright together.

### Gamma silently stopped working on recent macOS

Worth stating separately, because it changes the calculus for anyone considering the
gamma approach today. There are open Apple Feedback reports (FB18559786, FB19136488) that
`CGSetDisplayTransferByTable` is silently ignored on macOS Tahoe when "Automatically
adjust brightness" is enabled: the call reports success and nothing happens. The reporter
notes it affects BetterDisplay, MonitorControl, f.lux and Lunar. Apple's DTS response is
that the bug is open and under investigation.

Combined with the crash-safety problem — a process that dies holding a modified gamma ramp
can leave someone's display visibly wrong with no obvious remedy — this is why the gain
here is done entirely in the compositor.

### Battery and heat

**Fix.** Automatic pause when `ProcessInfo.thermalState` reaches serious or critical, with
automatic resume; optional pause in Low Power Mode; the EDR anchor is only lit while a
boost is actually wanted, so the panel is not held in a high-power state at 1.0×; and
redraws only happen when the gain actually changes, not every frame.

---

## Going darker than macOS allows

The dark half of the slider is the same mechanism with the multiplier below 1.0, so it is
one code path rather than a bolted-on second feature. Default range is 3 stops below the
macOS floor — one eighth of minimum brightness — adjustable up to 5.

Two honest caveats:

- **The mouse cursor is not affected.** macOS draws the hardware cursor above all
  windows, so it stays at full brightness. Everything else dims. There is no public API
  that fixes this; it is a real limitation of any overlay-based dimmer.
- **Banding.** Multiplying down compresses the tonal range. The compositor works in
  half-float and dithers, so it holds up much better than a gamma ramp would, but at the
  bottom of the range on a dark image you may see it. Lowering the hardware brightness
  first and only then using the dark half of this slider gives the best result.

---

## Architecture

```
main.swift                  NSApplication bootstrap, accessory activation policy
Core/DisplayInventory.swift Display enumeration, EDR capability, clamshell detection
Core/Overlay.swift          The two windows and the shader-free Metal renderer
Core/BrightnessEngine.swift Gain curve, headroom filtering, slew limiting, suspension
Core/SystemWatcher.swift    Every notification that can invalidate our state
Core/Settings.swift         UserDefaults-backed preferences
UI/MenuBarController.swift  Status item and popover
UI/ControlPanel.swift       The slider
```

The renderer is worth a note: it draws a flat colour using nothing but the render pass
clear value. No shaders, no vertex buffers, no draw calls. `MTLClearColor(red: g, green:
g, blue: g, alpha: 1)` into an `rgba16Float` `CAMetalLayer` with
`wantsExtendedDynamicRangeContent = true` and an extended linear Display P3 colour space,
with `compositingFilter = "multiplyBlendMode"` on the layer. That is the entire brightness
mechanism.

### The gain curve

Both halves of the slider are exponential in stops rather than linear in multiplier, so a
given movement of the thumb produces roughly the same perceived change wherever you are on
the track:

```
position >= 0   gain = 2 ^ (position × log2(ceiling))
position <  0   gain = 2 ^ (position × dimStops)

ceiling = clamp(min(grantedHeadroom, sustainedCap) × (1 − reserve), lower: 1.0)
```

---

## Building

Requires macOS 14 or later and the Xcode command line tools.

```
./Scripts/build-app.sh
open build/Overbright.app
```

The script produces an ad-hoc signed bundle, which is enough to run it yourself. Sign with
a Developer ID identity and notarise before distributing.

## Compatibility

| Hardware | Boost | Dim below minimum |
| --- | --- | --- |
| MacBook Pro 14"/16", M1 Pro or later | Yes | Yes |
| Pro Display XDR | Yes | Yes |
| Apple Studio Display, MacBook Air, Intel Macs | No extended range to unlock | Yes |
| Third-party HDR displays | Depends on reported headroom | Yes |

The app reads `maximumPotentialExtendedDynamicRangeColorComponentValue` and tells you in
the popover when there is nothing to unlock rather than pretending to boost.

## Known limitations

- HDR video is multiplied along with everything else while a boost is applied, so
  highlights in HDR content will clip. This is inherent to any full-screen gain approach;
  BrightIntosh documents the same behaviour. Right-click the menu bar icon to toggle off
  before watching HDR video.
- The mouse cursor is unaffected in both directions.
- Turning off "Automatically adjust brightness" in System Settings gives noticeably more
  consistent results, because the ambient light sensor otherwise keeps moving the SDR
  white point the headroom is measured against.

## Status

The code is complete and commented but has not been compiled or run on XDR hardware — the
machine it was written on has no Swift toolchain and no display to test against. Treat the
first build as a first build. The parts most likely to need adjustment on real hardware are
the slew rates, the 450 ms hysteresis delay and the 12% headroom reserve, all of which are
constants at the top of `BrightnessEngine.swift`.

## Prior art

- [BrightIntosh](https://github.com/niklasr22/BrightIntosh) — the actively maintained
  open-source option; its release notes were the single best source of real-world failure
  modes for this project.
- [BrightXDR](https://github.com/starkdmi/BrightXDR) — unmaintained, but its README
  documents the Core Image / Metal EDR overlay approach clearly.
- [Vivid](https://www.getvivid.app/) — the original, and the source of the 1000-nits-not-1600
  reasoning used here.
- [BetterDisplay](https://github.com/waydabber/BetterDisplay) — its XDR upscaling wiki page
  is the best public explanation of how EDR headroom relates to the brightness setting.
