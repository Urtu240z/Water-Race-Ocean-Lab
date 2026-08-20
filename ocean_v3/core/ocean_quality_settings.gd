extends Node
## Perfiles de infraestructura. Sus parámetros llegarán con los módulos futuros.

signal profile_changed(profile: int)

enum Profile {
	DECK,
	STANDARD,
	DEV_HIGH,
}

var active_profile: int = Profile.STANDARD


func set_profile(profile: int) -> void:
	if profile < Profile.DECK or profile > Profile.DEV_HIGH:
		push_warning("Perfil Ocean V3 no válido: %s" % profile)
		return
	if active_profile == profile:
		return
	active_profile = profile
	profile_changed.emit(active_profile)


func cycle_profile() -> void:
	set_profile((active_profile + 1) % (Profile.DEV_HIGH + 1))


func profile_name() -> String:
	match active_profile:
		Profile.DECK:
			return "DECK"
		Profile.STANDARD:
			return "STANDARD"
		Profile.DEV_HIGH:
			return "DEV_HIGH"
	return "UNKNOWN"
