extends SceneTree

func _init() -> void:
	for path in ["res://env/sky.hdr", "res://env/sky_night.hdr"]:
		var tex := load(path) as Texture2D
		var img := tex.get_image()
		if img.is_compressed():
			img.decompress()
		img.resize(64, 32, Image.INTERPOLATE_BILINEAR)
		var top := Color(0, 0, 0)
		var hor := Color(0, 0, 0)
		var mx := 0.0
		for y in range(32):
			for x in range(64):
				var c := img.get_pixel(x, y)
				mx = maxf(mx, c.get_luminance())
				if y < 12:
					top += c
				elif y < 17:
					hor += c
		print("%s fmt=%d size=%s top=%s horizon=%s max=%.2f" % [path, img.get_format(), str(tex.get_size()), str(top / (12.0 * 64.0)), str(hor / (5.0 * 64.0)), mx])
	quit(0)
