# Game fails to load, black screen or heavy glitching (GPU memory)

## Symptoms

- The window stays black or shows the city in pieces for a long time, at 1 fps or so.
- Textures flicker, go missing or turn to garbage; the game may crash.
- The log shows `VkResult -2` (`VK_ERROR_OUT_OF_DEVICE_MEMORY`), `vkAllocateMemory failed` or
  `Unable to create local RenderingDevice`.

## Confirm

1. The first log line of a run says what the game found:
   `GridFall GPU: <card>, <total> MiB, <free> MiB free: low GPU memory mode (...)` or `full GPU memory`.
2. See what else holds GPU memory: `nvidia-smi` (NVIDIA) or `cat /sys/class/drm/card*/device/mem_info_vram_used`
   (AMD). GridFall needs about 0.9 GB in low GPU memory mode and 1.2 GB otherwise (1280x720).
   Local LLM servers (Ollama, llama.cpp, LM Studio), another game, a Godot editor and browsers with
   many tabs are the usual holders.

## Fix

1. Free the memory: quit the other program, or unload its model (`ollama stop <model>`; `ollama ps`
   lists the loaded ones). `sudo systemctl stop ollama` stops the service until the next boot.
2. On a card with 4 GB or less, an integrated GPU or with under 1.5 GB free at startup the game
   switches to low GPU memory mode by itself (`scripts/ops/gpu_memory.gd`): smaller shadow maps,
   FXAA instead of MSAA, lighter SSAO and the Low preset in first person. Force it on a bigger card
   with `GRIDFALL_LOW_VRAM=1 godot --path .`, or off with `GRIDFALL_LOW_VRAM=0`.
3. A Quality preset saved in the pause menu (Esc > Display) wins over the automatic Low; pick Low
   there, or delete `user://gridfall_fp_settings.json` to go back to the automatic choice.

## Verify

The city appears within about ten seconds, the log has no `VkResult` errors and the game runs
smoothly.
