extends RefCounted
## Binary min-heap of (priority, int item) for the lane and sidewalk A* searches.

var _p := PackedFloat32Array()
var _v := PackedInt32Array()


func is_empty() -> bool:
	return _v.is_empty()


func size() -> int:
	return _v.size()


func push(p: float, v: int) -> void:
	_p.append(p)
	_v.append(v)
	var i := _v.size() - 1
	while i > 0:
		var parent := (i - 1) >> 1
		if _p[parent] <= _p[i]:
			break
		_swap(i, parent)
		i = parent


## Removes and returns the item with the lowest priority (the heap must not be empty).
func pop() -> int:
	var top := _v[0]
	var last := _v.size() - 1
	_swap(0, last)
	_p.resize(last)
	_v.resize(last)
	var i := 0
	while true:
		var l := i * 2 + 1
		var r := l + 1
		var m := i
		if l < last and _p[l] < _p[m]:
			m = l
		if r < last and _p[r] < _p[m]:
			m = r
		if m == i:
			break
		_swap(i, m)
		i = m
	return top


func _swap(a: int, b: int) -> void:
	var tp := _p[a]
	_p[a] = _p[b]
	_p[b] = tp
	var tv := _v[a]
	_v[a] = _v[b]
	_v[b] = tv
