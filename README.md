# Instreamer

This is a library for doing per-player instance streaming in Roblox, allowing instances to be used with the same level of convenience as Roblox's built-in assets (such as images, sounds, and animations). Due to this similarity this library refers to such instances as "assets".

For reading the code, I recommend a tab width of 3 since that's what I wrote it with (and my Luau formatting style depends on tab width). Unfortunately GitHub does not provide this tab width as a selectable option, but you can get it for a particular file by appending `?ts=3` to the end of the file's URL.

At the moment, this library provides:
- A client-initiated subscription approach to streaming instances
- Client-side immediate-mode and retained-mode APIs for streaming instances
- Server-side utilities for sending instances to players via PlayerGui
- Lots of flexibility:
   - Assets are identified by strings, with an optional convention for handling different asset types that may share names
   - The server can respond with anything it likes to any player including generating instances on the fly
   - High-level API for developers who just want plug & play asset streaming
   - Low-level API for developers who want a bit more control over things like code execution

Future plans:
- Confirm whether instances replicate atomically through PlayerGui or not. (They appear to be atomic in my experience so far.)
- Immediate-mode and retained-mode APIs to allow the server to decide to globally replicate assets to all players while keeping the same client-side API.
- Maybe: Allowances for different expiry timings/conditions for cached assets client-side.
