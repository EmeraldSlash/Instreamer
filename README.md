# Instreamer

This is a library for doing per-player instance streaming in Roblox, allowing instances to be used with the same level of convenience as Roblox's built-in assets (such as images, sounds, and animations). Due to this similarity this library refers to such instances as "assets".

For reading the code, I recommend a tab width of 3 since that's what I wrote it with (and my Luau formatting style depends on tab width). Unfortunately GitHub does not provide this tab width as a selectable option, but you can get it for a particular file by appending `?ts=3` to the end of the file's URL.

At the moment, this library provides:
- Both client-initiated and server-initiated approaches to streaming instances
- Client-side immediate-mode and retained-mode APIs for streaming instances
- Server-side utilities for sending instances to players via PlayerGui
- Lots of flexibility:
   - Assets are identified by strings, with an optional convention for namespacing different asset types
   - The server can respond with anything it likes to any player including generating instances on the fly
   - High-level API ("HAPI") for developers who just want plug & play asset streaming
   - Low-level API ("LAPI") for developers who want a bit more control over things like code execution

Future plans:
- Improve the APIs by making all top-level HAPI functions be methods on a StreamerClient. This should reduce unnecessary separation between HAPI and LAPI, and also improve the HAPI UX by more readily enabling a StreamerClient to be passed around in usage code rather than having to require the module unnecessarily. But I'm not sure whether to keep the top-level HAPI functions or require that all usage always index into a default Instreamer.StreamerClient field?
- Confirm whether instances replicate atomically through PlayerGui or not. (They appear to be atomic in my experience so far.)
- Maybe: Allowances for different expiry timings/conditions for cached assets client-side.
