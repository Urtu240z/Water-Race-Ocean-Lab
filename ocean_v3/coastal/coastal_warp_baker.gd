class_name CoastalWarpBaker
extends RefCounted
## Fase 3B.2A: construye el mapping world_xz -> deep_xz a partir de un
## CoastalPropagationData de 3B.1 (Eikonal). NO toca el FFT ni H0.
##
## Convenio:
##   d0 = incoming_direction (unitario)
##   n0 = perpendicular(d0)
##   s_deep = phi / k0  (coordenada longitudinal: fase Eikonal / k0)
##   r_deep = dot(p_frontera_upstream, n0)  (backtrace con -local_direction)
##   deep_xz = deep_origin + d0*s_deep + n0*r_deep
##   deep_origin = d0 * min_s  (con min_s = min dot(world, d0) en el grid)
##
## En fondo plano el mapping es la IDENTIDAD (deep_xz ~= world_xz).
##
## Backtrace: RK2 (Heun) sobre -local_direction interpolada bilinealmente,
## paso inicial = backtrace_step_cells * cell_size. Al cruzar la frontera
## upstream se guarda r_deep = dot(p_cruce, n0). Si el backtrace entra en
## tierra/shadow o agota pasos, el nodo queda INVALID (no se cruza tierra).

const WarpDataScript := preload("res://ocean_v3/coastal/coastal_warp_data.gd")

var propagation: CoastalPropagationData
var backtrace_step_cells := 0.5
var max_backtrace_steps := 0 # 0 => automático (4 * max(w,h) / step_cells + 32).
var detj_safe_threshold := 0.5
# Perfilado (diagnóstico de coste 3B.2A).
var diag_total_steps := 0
var diag_time_sample_direction_us := 0
var diag_time_integration_us := 0
var diag_time_jacobian_us := 0
var diag_time_total_us := 0


func bake():
	if propagation == null or not propagation.is_valid():
		push_error("CoastalWarpBaker requiere CoastalPropagationData válido.")
		return null
	if propagation.propagation_kind != 1:
		push_warning("CoastalWarpBaker: propagation_kind != EIKONAL_2D; el warp se construye igualmente.")
	var direction := propagation.incoming_direction_xz.normalized()
	if direction.length_squared() <= 1.0e-8 or propagation.k0_rad_m <= 0.0:
		push_error("CoastalWarpBaker requiere dirección y k0 válidos.")
		return null
	var normal := Vector2(-direction.y, direction.x)
	var width: int = propagation.width
	var height: int = propagation.height
	var cell: float = propagation.cell_size_m
	var origin: Vector2 = propagation.world_origin_xz
	var count := width * height

	var warp = WarpDataScript.new()
	warp.world_origin_xz = origin
	warp.width = width
	warp.height = height
	warp.cell_size_m = cell
	warp.incoming_direction_xz = direction
	warp.k0_rad_m = propagation.k0_rad_m
	warp.omega_ref_rad_s = propagation.omega_ref_rad_s
	warp.detj_safe_threshold = detj_safe_threshold
	warp.deep_x.resize(count)
	warp.deep_z.resize(count)
	warp.jacobian_det.resize(count)
	warp.jacobian_j00.resize(count)
	warp.jacobian_j01.resize(count)
	warp.jacobian_j10.resize(count)
	warp.jacobian_j11.resize(count)
	warp.valid_mask.resize(count)
	warp.r_deep.resize(count)
	warp.backtrace_steps.resize(count)
	warp.boundary_hit.resize(count)
	warp.jacobian_class.resize(count)
	# deep_origin = d0 * min_s: en flat anula la constante y da identidad.
	var minimum_s := INF
	for z in height:
		for x in width:
			var point: Vector2 = origin + Vector2(float(x), float(z)) * cell
			minimum_s = minf(minimum_s, point.dot(direction))
	warp.deep_origin_xz = direction * minimum_s

	var step_h := maxf(cell * backtrace_step_cells, 0.01)
	var max_steps := max_backtrace_steps if max_backtrace_steps > 0 else int(4.0 * float(maxi(width, height)) / step_h) + 32

	var bake_start := Time.get_ticks_usec()

	for z in height:
		for x in width:
			var index := z * width + x
			if propagation.valid_mask[index] == 0 or propagation.reached_mask[index] == 0:
				warp.valid_mask[index] = 0
				warp.jacobian_class[index] = WarpDataScript.JacobianClass.INVALID
				warp.jacobian_det[index] = 0.0
				continue
			var phase: float = propagation.phase_rad[index]
			var s_deep := phase / propagation.k0_rad_m
			var result: Dictionary = _backtrace(propagation, direction, normal, origin, cell, width, height,
				Vector2(float(x), float(z)), step_h, max_steps)
			diag_total_steps += int(result["steps"])
			var hit: int = result["hit"]
			warp.backtrace_steps[index] = int(result["steps"])
			warp.boundary_hit[index] = hit
			if hit == WarpDataScript.BoundaryHit.UPSTREAM:
				warp.valid_mask[index] = 1
				# El cruce está en celdas locales; r_deep usa world.
				var world_cross: Vector2 = origin + (result["cross_point"] as Vector2) * cell
				warp.r_deep[index] = world_cross.dot(normal)
			else:
				warp.valid_mask[index] = 0
				warp.r_deep[index] = 0.0
			if warp.valid_mask[index] != 0:
				var r_deep: float = warp.r_deep[index]
				var deep: Vector2 = warp.deep_origin_xz + direction * s_deep + normal * r_deep
				warp.deep_x[index] = deep.x
				warp.deep_z[index] = deep.y
			else:
				warp.deep_x[index] = 0.0
				warp.deep_z[index] = 0.0
			warp.jacobian_det[index] = 0.0
			warp.jacobian_class[index] = WarpDataScript.JacobianClass.INVALID

	var t_jac0 := Time.get_ticks_usec()
	_compute_jacobian(warp)
	diag_time_jacobian_us = Time.get_ticks_usec() - t_jac0
	diag_time_total_us = Time.get_ticks_usec() - bake_start
	return warp


## --- Backtrace de characteristics --------------------------------------------

func debug_sample_direction(prop_data, width: int, height: int, grid_local: Vector2) -> Dictionary:
	return _sample_direction(prop_data, width, height, grid_local)


func debug_backtrace(prop_data, direction: Vector2, origin: Vector2, cell: float,
		width: int, height: int, grid_local: Vector2, step_h: float, max_steps: int) -> Dictionary:
	return _backtrace(prop_data, direction, Vector2(-direction.y, direction.x), origin, cell,
		width, height, grid_local, step_h, max_steps)


func _backtrace(prop_data, direction: Vector2, _normal: Vector2, origin: Vector2, cell: float,
		width: int, height: int, grid_local: Vector2, step_h: float, max_steps: int) -> Dictionary:
	## Integra p' = -local_direction(p) desde grid_local (en celdas, local al
	## grid) hacia aguas arriba hasta tocar la frontera upstream.
	## Devuelve {steps:int, hit:BoundaryHit, cross_point:Vector2 (celdas)}.
	var t_backtrace0 := Time.get_ticks_usec()
	var result := {"steps": 0, "hit": WarpDataScript.BoundaryHit.NONE, "cross_point": Vector2.ZERO}
	var p := grid_local
	var t_s0 := Time.get_ticks_usec()
	var dir_sample: Dictionary = _sample_direction(prop_data, width, height, p)
	diag_time_sample_direction_us += Time.get_ticks_usec() - t_s0
	if not dir_sample["valid"]:
		result["hit"] = WarpDataScript.BoundaryHit.LAND_OR_SHADOW
		diag_time_integration_us += Time.get_ticks_usec() - t_backtrace0
		return result
	var dir: Vector2 = dir_sample["dir"]
	for _step in max_steps:
		result["steps"] = int(result["steps"]) + 1
		# RK2 / Heun: k1 = dir(p), k2 = dir(p - h*k1/2).
		var mid := p - dir * (0.5 * step_h)
		var dir_mid := dir
		# Si el punto medio sale del grid, no es tierra: es cruce de frontera.
		# Degradamos a Euler (k2 = k1) para que el segmento p->next se interseque
		# correctamente con el borde.
		if mid.x >= 0.0 and mid.y >= 0.0 and mid.x <= float(width - 1) and mid.y <= float(height - 1):
			var t_s1 := Time.get_ticks_usec()
			var mid_sample: Dictionary = _sample_direction(prop_data, width, height, mid)
			diag_time_sample_direction_us += Time.get_ticks_usec() - t_s1
			if not mid_sample["valid"]:
				result["hit"] = WarpDataScript.BoundaryHit.LAND_OR_SHADOW
				return result
			dir_mid = mid_sample["dir"]
		var next := p - dir_mid * step_h
		# No entrar en tierra: comprobar el punto destino.
		var dir_next := dir
		if next.x >= 0.0 and next.y >= 0.0 and next.x <= float(width - 1) and next.y <= float(height - 1):
			var t_s2 := Time.get_ticks_usec()
			var next_sample: Dictionary = _sample_direction(prop_data, width, height, next)
			diag_time_sample_direction_us += Time.get_ticks_usec() - t_s2
			if not next_sample["valid"]:
				result["hit"] = WarpDataScript.BoundaryHit.LAND_OR_SHADOW
				diag_time_integration_us += Time.get_ticks_usec() - t_backtrace0
				return result
			dir_next = next_sample["dir"]
		# ¿Cruza la frontera del grid? Interseca el segmento p->next con el borde.
		if next.x < 0.0 or next.y < 0.0 or next.x > float(width - 1) or next.y > float(height - 1):
			var cross := _intersect_grid_border(p, next, width, height)
			result["cross_point"] = cross
			result["hit"] = _classify_cross(direction, cross, width, height)
			diag_time_integration_us += Time.get_ticks_usec() - t_backtrace0
			return result
		p = next
		dir = dir_next
	result["hit"] = WarpDataScript.BoundaryHit.STEPS_EXCEEDED
	diag_time_integration_us += Time.get_ticks_usec() - t_backtrace0
	return result


func _sample_direction(prop_data, width: int, height: int, grid_local: Vector2) -> Dictionary:
	## Dirección local interpolada bilinealmente; devuelve {valid, dir}.
	## valid=false si el punto cae en tierra/shadow (no se atraviesa).
	## Hot path del backtrace: interpola SÓLO dirección+reached (no los 10
	## campos de sample_propagation), que es lo que necesita el RK2.
	if grid_local.x < 0.0 or grid_local.y < 0.0 or grid_local.x > float(width - 1) or grid_local.y > float(height - 1):
		return {"valid": false, "dir": Vector2.ZERO}
	var x0 := mini(int(floor(grid_local.x)), width - 2)
	var z0 := mini(int(floor(grid_local.y)), height - 2)
	var tx := grid_local.x - float(x0)
	var tz := grid_local.y - float(z0)
	var i00 := z0 * width + x0
	var i10 := i00 + 1
	var i01 := i00 + width
	var i11 := i01 + 1
	# reached/valid por nearest (como sample_propagation): no atravesar
	# tierra/shadow.
	var nearest := clampi(int(round(grid_local.y)), 0, height - 1) * width + clampi(int(round(grid_local.x)), 0, width - 1)
	if prop_data.valid_mask[nearest] == 0 or prop_data.reached_mask[nearest] == 0:
		return {"valid": false, "dir": Vector2.ZERO}
	var w00 := (1.0 - tx) * (1.0 - tz)
	var w10 := tx * (1.0 - tz)
	var w01 := (1.0 - tx) * tz
	var w11 := tx * tz
	var dir_x: float = prop_data.local_direction_x[i00] * w00 + prop_data.local_direction_x[i10] * w10 + prop_data.local_direction_x[i01] * w01 + prop_data.local_direction_x[i11] * w11
	var dir_z: float = prop_data.local_direction_z[i00] * w00 + prop_data.local_direction_z[i10] * w10 + prop_data.local_direction_z[i01] * w01 + prop_data.local_direction_z[i11] * w11
	var direction := Vector2(dir_x, dir_z).normalized()
	if direction.length_squared() <= 1.0e-12:
		return {"valid": false, "dir": Vector2.ZERO}
	return {"valid": true, "dir": direction}


func _intersect_grid_border(p: Vector2, next: Vector2, width: int, height: int) -> Vector2:
	## Intersección del segmento p->next con el rectángulo [0,w-1]x[0,h-1].
	var t := 1.0
	var delta := next - p
	if delta.x < 0.0 and p.x <= float(width - 1) and next.x < 0.0:
		t = minf(t, (0.0 - p.x) / delta.x)
	elif delta.x > 0.0 and p.x >= 0.0 and next.x > float(width - 1):
		t = minf(t, (float(width - 1) - p.x) / delta.x)
	if delta.y < 0.0 and p.y <= float(height - 1) and next.y < 0.0:
		t = minf(t, (0.0 - p.y) / delta.y)
	elif delta.y > 0.0 and p.y >= 0.0 and next.y > float(height - 1):
		t = minf(t, (float(height - 1) - p.y) / delta.y)
	return p + delta * maxf(t, 0.0)


func _classify_cross(direction: Vector2, cross: Vector2, width: int, height: int) -> int:
	## Un cruce es UPSTREAM si el punto anterior a lo largo de -direction está
	## fuera del grid (mismo criterio que la frontera del solve eikonal).
	var before := cross - direction
	if before.x < 0.0 or before.y < 0.0 or before.x > float(width - 1) or before.y > float(height - 1):
		return WarpDataScript.BoundaryHit.UPSTREAM
	# Si el cruce no es upstream (lateral o downstream), comprobamos si es válido
	# pero no es la frontera de entrada: se marca LATERAL (warp inválido, no se
	# puede etiquetar el characteristic desde la frontera de entrada).
	return WarpDataScript.BoundaryHit.LATERAL


## --- Jacobiano ----------------------------------------------------------------

func _compute_jacobian(warp) -> void:
	var width: int = warp.width
	var height: int = warp.height
	var cell: float = warp.cell_size_m
	var threshold: float = warp.detj_safe_threshold
	for z in height:
		for x in width:
			var index := z * width + x
			if warp.valid_mask[index] == 0:
				continue
			# Buscar vecinos VÁLIDOS en ±1 celda; los inválidos (tierra/shadow/
			# backtrace lateral) tienen deep=0 y contaminarían la diferencia.
			var xm := x - 1
			var xp := x + 1
			var zm := z - 1
			var zp := z + 1
			if xm < 0 or warp.valid_mask[z * width + xm] == 0:
				xm = x
			if xp >= width or warp.valid_mask[z * width + xp] == 0:
				xp = x
			if zm < 0 or warp.valid_mask[zm * width + x] == 0:
				zm = z
			if zp >= height or warp.valid_mask[zp * width + x] == 0:
				zp = z
			var hx := float(xp - xm) * cell
			var hz := float(zp - zm) * cell
			if hx <= 0.0 or hz <= 0.0:
				# Sin vecinos válidos en X o Z: jacobiano indeterminado.
				warp.jacobian_det[index] = 0.0
				warp.jacobian_class[index] = WarpDataScript.JacobianClass.NEAR_CAUSTIC
				continue
			var dxx: float = (warp.deep_x[z * width + xp] - warp.deep_x[z * width + xm]) / hx
			var dzx: float = (warp.deep_z[z * width + xp] - warp.deep_z[z * width + xm]) / hx
			var dxz: float = (warp.deep_x[zp * width + x] - warp.deep_x[zm * width + x]) / hz
			var dzz: float = (warp.deep_z[zp * width + x] - warp.deep_z[zm * width + x]) / hz
			var det: float = dxx * dzz - dxz * dzx
			warp.jacobian_j00[index] = dxx
			warp.jacobian_j01[index] = dxz
			warp.jacobian_j10[index] = dzx
			warp.jacobian_j11[index] = dzz
			warp.jacobian_det[index] = det
			if det > threshold:
				warp.jacobian_class[index] = WarpDataScript.JacobianClass.SAFE
			elif det > 0.0:
				warp.jacobian_class[index] = WarpDataScript.JacobianClass.NEAR_CAUSTIC
			else:
				warp.jacobian_class[index] = WarpDataScript.JacobianClass.FOLDED
