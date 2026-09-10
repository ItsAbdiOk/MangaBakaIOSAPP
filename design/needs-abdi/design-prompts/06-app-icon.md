# App icon

**Status:** an off-brand purple placeholder. It ships to your testers' home
screens the moment TestFlight goes out.

## What it has to work with

- Accent `#F87966` — the sRGB of the mockup's `oklch(0.72 0.16 30)`
- Dark-first palette; the app has no light mode
- The `BAKAMANGA` wordmark exists in the mockup as `typeWordmark()`

## What it has to survive

- 1024px down to a 40px Spotlight result
- iOS 26 wants **light, dark, and tinted** variants; tinted is a single-channel
  mask, so anything that depends on colour to be legible disappears in it
- Home-screen dark mode, where a dark icon on a dark wallpaper vanishes

## What it must not be

A book. A stack of books. An open book with a bookmark. Every manga app on the
store is a book.

## What to hand back

1024×1024 for light, dark and tinted, plus a screenshot of all three on a real
home screen next to other apps.
