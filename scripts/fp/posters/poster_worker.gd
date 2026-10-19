extends RefCounted
## One background thread that runs poster image jobs in order (slice D): decode, resize, WebP,
## mipmaps and VRAM compression. A plain Thread rather than WorkerThreadPool tasks: Image.compress
## may fan out onto the pool and wait for it, which can starve when the caller is itself a pool
## task. Jobs touch only their own input dictionary; the main thread collects finished inputs
## with take_done().

var _thread: Thread
var _mutex := Mutex.new()
var _sem := Semaphore.new()
var _jobs: Array = []
var _done: Array = []
var _running: int = 0
var _stop: bool = false


## Job for composites: opaque RGB, mipmaps and block compression of input.image; sets input.ok.
static func finish_image(input: Dictionary) -> void:
	var img: Image = input["image"]
	if img == null or img.is_empty():
		return
	img.convert(Image.FORMAT_RGB8)
	img.generate_mipmaps()
	if OS.has_feature("s3tc"):
		img.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_SRGB)
	input["ok"] = true


## Starts the thread on first use.
func _ensure() -> void:
	if _thread == null:
		_stop = false
		_thread = Thread.new()
		_thread.start(_loop)


## Queues fn.call(input) on the thread.
func push(fn: Callable, input: Dictionary) -> void:
	_ensure()
	_mutex.lock()
	_jobs.append([fn, input])
	_mutex.unlock()
	_sem.post()


## Inputs whose job finished since the last call, in order.
func take_done() -> Array:
	_mutex.lock()
	var d := _done
	_done = []
	_mutex.unlock()
	return d


## Jobs queued or running.
func pending() -> int:
	_mutex.lock()
	var n := _jobs.size() + _running
	_mutex.unlock()
	return n


## Drops queued jobs, lets a running one finish and joins the thread.
func stop() -> void:
	if _thread == null:
		return
	_mutex.lock()
	_stop = true
	_jobs.clear()
	_mutex.unlock()
	_sem.post()
	_thread.wait_to_finish()
	_thread = null
	_done.clear()


func _loop() -> void:
	while true:
		_sem.wait()
		_mutex.lock()
		if _stop:
			_mutex.unlock()
			return
		var job: Array = _jobs.pop_front() if not _jobs.is_empty() else []
		if not job.is_empty():
			_running = 1
		_mutex.unlock()
		if job.is_empty():
			continue
		(job[0] as Callable).call(job[1])
		_mutex.lock()
		_running = 0
		_done.append(job[1])
		_mutex.unlock()
