extends Node2D

# --- Detección ---
const DECIMATE := 2                # Reduce la frecuencia de muestreo (48 kHz -> 24 kHz) para ir más rápido
const WINDOW := 512                # Muestras por análisis (tras decimar)
const MIN_FREQ := 180.0            # Algo por debajo del Sol3 del violín (~196 Hz)
const MAX_FREQ := 2000.0
const YIN_THRESHOLD := 0.15        # Más bajo = más exigente. Subirlo favorece errores de octava
const OCTAVE_RATIO := 0.5          # Corrección de octava: ver _detect_pitch()
const SILENCE_RMS := 0.001          # Por debajo de este volumen se considera silencio
const ANALYSIS_INTERVAL := 0.1     # Segundos entre análisis
const SMOOTHING := 3               # Nº de lecturas para la mediana (quita saltos sueltos)
const A4 := 440.0
const NOTE_NAMES := ["Do", "Do#", "Re", "Re#", "Mi", "Fa", "Fa#", "Sol", "Sol#", "La", "La#", "Si"]

# --- Juego ---
# Notas de principiante como números MIDI (La4 = 69 = 440 Hz):
# Sol3 La3 Si3 Do4 Re4 Mi4 Fa#4 Sol4 La4 Si4 Do#5 Re5 Mi5 Fa#5 Sol#5 La5
const TARGET_NOTES := [55, 57, 59, 60, 62, 64, 66, 67, 69, 71, 73, 74, 76, 78, 80, 81]
const TOLERANCE_CENTS := 40.0      # Margen de principiante (50 sería ya la mitad del semitono vecino)
const HOLD_TIME := 0.15            # Segundos que hay que mantener una nota para que cuente (acierto o fallo)
const FAIL_DISPLAY_TIME := 2.0     # Segundos mínimos que se queda visible el mensaje de fallo

# Clasificación de cada lectura (las notas incorrectas usan su número MIDI)
const KEY_NONE := -1
const KEY_OK := 1000
const KEY_OUT_OF_TUNE := 1001

@onready var label: Label = $Label
@onready var target_label: Label = $TargetLabel
@onready var result_label: Label = $ResultLabel
@onready var score_label: Label = $ScoreLabel
@onready var staff: Staff = $Staff

var sample_rate: float
var tau_min: int
var tau_max: int
var buffer := PackedFloat32Array()
var dec_acc := 0.0
var dec_count := 0
var time_since_analysis := 0.0
var backlog_ms := 0.0              # Audio atrasado que había en el buffer del micro (diagnóstico)
var recent_midi: Array[float] = [] # Últimas lecturas, para la mediana
var octave_fixes := 0              # Cuántas veces ha corregido la octava (diagnóstico)

var target_midi := -1
var solved := false
var hits := 0
var misses := 0
var pending_key := KEY_NONE        # Lo que se está tocando ahora mismo...
var pending_time := 0.0            # ...y cuánto tiempo lleva estable
var last_fail_key := KEY_NONE      # Último fallo contado (para no contar dos veces la misma nota sostenida)
var fail_display_left := 0.0       # Tiempo que le queda al mensaje de fallo en pantalla


func _ready() -> void:
	_new_target()
	_update_score()

	# Leemos el micro directamente del AudioServer (API experimental de Godot 4.6+),
	# sin AudioStreamPlayer ni bus: así controlamos el buffer y descartamos lo atrasado.
	var err := AudioServer.set_input_device_active(true)
	if err != OK:
		label.text = "No se pudo abrir el micrófono (error %d).\n¿Está activado Audio > Driver > Enable Input?" % err
		set_process(false)
		return

	var input_rate := AudioServer.get_input_mix_rate()
	if input_rate <= 0.0:
		input_rate = AudioServer.get_mix_rate()
	sample_rate = input_rate / DECIMATE
	tau_min = int(sample_rate / MAX_FREQ)
	tau_max = int(sample_rate / MIN_FREQ) + 1
	label.text = "Escuchando... (%d Hz)" % int(input_rate)


func _exit_tree() -> void:
	AudioServer.set_input_device_active(false)


func _input(event: InputEvent) -> void:
	# Espacio o Enter: nueva nota. Comprobamos la tecla directamente
	# para no depender del mapa de acciones ni de que otro nodo la consuma.
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode in [KEY_SPACE, KEY_ENTER, KEY_KP_ENTER]:
			_new_target()
			get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	_read_microphone()

	time_since_analysis += delta
	if time_since_analysis < ANALYSIS_INTERVAL:
		return
	var elapsed := time_since_analysis
	time_since_analysis = 0.0

	if buffer.size() < WINDOW + tau_max + 1:
		return

	var rms := _rms()
	var info := "vol %.3f · retraso descartado %d ms · octavas corregidas %d" % [rms, int(backlog_ms), octave_fixes]

	if rms < SILENCE_RMS:
		recent_midi.clear()
		label.text = "Silencio\n" + info
		_update_game(-1.0, elapsed)
		return

	var freq := _detect_pitch()
	if freq <= 0.0:
		recent_midi.clear()
		label.text = "Sin tono claro\n" + info
		_update_game(-1.0, elapsed)
		return

	recent_midi.append(_freq_to_midi(freq))
	if recent_midi.size() > SMOOTHING:
		recent_midi.pop_front()
	var smoothed := _median(recent_midi)

	label.text = "%.1f Hz (instantáneo)\n%s\n%s" % [freq, _describe_midi(smoothed), info]
	_update_game(smoothed, elapsed)


# ---------------------------------------------------------------- Juego

func _new_target() -> void:
	var next: int = TARGET_NOTES.pick_random()
	while next == target_midi:
		next = TARGET_NOTES.pick_random()
	target_midi = next
	solved = false
	pending_key = KEY_NONE
	pending_time = 0.0
	last_fail_key = KEY_NONE
	fail_display_left = 0.0
	target_label.text = "Toca: " + _note_name(target_midi)
	staff.set_note(target_midi)
	_show_result("Toca la nota...", Color.WHITE)


# midi < 0 significa "no hay tono"
func _update_game(midi: float, elapsed: float) -> void:
	# Cuenta atrás del mensaje de fallo
	if fail_display_left > 0.0:
		fail_display_left = maxf(fail_display_left - elapsed, 0.0)

	if solved:
		return  # Se queda en "¡Correcto!" hasta que pidas otra nota

	var showing_fail := fail_display_left > 0.0

	if midi < 0.0:
		pending_key = KEY_NONE
		pending_time = 0.0
		last_fail_key = KEY_NONE  # Tras un silencio, la misma nota mal vuelve a contar como fallo
		if not showing_fail:
			_show_result("Toca la nota...", Color.WHITE)
		return

	# ¿Lleva estable lo que se está tocando?
	var key := _classify(midi)
	if key == pending_key:
		pending_time += elapsed
	else:
		pending_key = key
		pending_time = elapsed
	var stable := pending_time >= HOLD_TIME

	# Nota correcta: un acierto confirmado sustituye incluso a un mensaje de fallo
	if key == KEY_OK:
		if stable:
			solved = true
			hits += 1
			fail_display_left = 0.0
			_update_score()
			_show_result("¡Correcto!\nPulsa Espacio para otra nota", Color.GREEN)
		elif not showing_fail:
			_show_result("¡Ahí está! Mantenla...", Color.YELLOW)
		return

	# Nota incorrecta o desafinada
	if stable and not showing_fail and key != last_fail_key:
		# Fallo nuevo: se cuenta y el mensaje se queda FAIL_DISPLAY_TIME segundos
		misses += 1
		last_fail_key = key
		fail_display_left = FAIL_DISPLAY_TIME
		_update_score()
		_show_fail(midi, key)
	elif stable and not showing_fail:
		# Sigue sosteniendo la misma nota mal: se muestra, pero no se cuenta otra vez
		_show_fail(midi, key)
	elif not showing_fail:
		_show_result("Escuchando...", Color.WHITE)


func _classify(midi: float) -> int:
	if absf(midi - target_midi) * 100.0 <= TOLERANCE_CENTS:
		return KEY_OK
	var played := roundi(midi)
	if played == target_midi:
		return KEY_OUT_OF_TUNE
	return played


func _show_fail(midi: float, key: int) -> void:
	var direction := "más agudo" if midi < target_midi else "más grave"
	if key == KEY_OUT_OF_TUNE:
		_show_result("Desafinado: ve un poco %s" % direction, Color.ORANGE)
	else:
		_show_result("Incorrecto: tocas %s\n(ve %s)" % [_note_name(key), direction], Color.RED)


func _show_result(text: String, color: Color) -> void:
	result_label.text = text
	result_label.modulate = color
	# La nota del pentagrama toma el color del resultado (verde, rojo, naranja);
	# en los estados neutros (blanco, amarillo) vuelve a negro.
	if color == Color.WHITE or color == Color.YELLOW:
		staff.set_note_color(Staff.INK)
	else:
		staff.set_note_color(color.darkened(0.25))


func _update_score() -> void:
	score_label.text = "Aciertos: %d   Fallos: %d" % [hits, misses]


# ---------------------------------------------------------------- Audio

# Lee del micro solo lo más reciente: si se ha acumulado más audio del que
# necesitamos para un análisis, lo antiguo se tira. Esto es lo que evita el lag.
func _read_microphone() -> void:
	var available := AudioServer.get_input_frames_available()
	if available <= 0:
		return

	var max_frames := (WINDOW + tau_max + 1) * DECIMATE
	if available > max_frames:
		var discard := available - max_frames
		AudioServer.get_input_frames(discard)
		backlog_ms = discard * 1000.0 / (sample_rate * DECIMATE)
		available = max_frames
	else:
		backlog_ms = 0.0

	var stereo := AudioServer.get_input_frames(available)
	for f: Vector2 in stereo:
		dec_acc += f.x
		#dec_acc += (f.x + f.y) * 0.5
		dec_count += 1
		if dec_count == DECIMATE:
			buffer.append(dec_acc / DECIMATE)
			dec_acc = 0.0
			dec_count = 0

	var needed := WINDOW + tau_max + 1
	if buffer.size() > needed:
		buffer = buffer.slice(buffer.size() - needed)


func _rms() -> float:
	var s := 0.0
	for x in buffer:
		s += x * x
	return sqrt(s / buffer.size())


# Algoritmo YIN (de Cheveigné & Kawahara, 2002) con corrección de octava.
# Devuelve la frecuencia fundamental en Hz, o -1 si no hay un tono claro.
func _detect_pitch() -> float:
	# 1-2. Función de diferencia y su versión normalizada (CMNDF)
	var d := PackedFloat32Array()
	d.resize(tau_max + 1)
	d[0] = 1.0
	var running_sum := 0.0
	for tau in range(1, tau_max + 1):
		var s := 0.0
		for j in WINDOW:
			var diff := buffer[j] - buffer[j + tau]
			s += diff * diff
		running_sum += s
		d[tau] = s * tau / running_sum if running_sum > 0.0 else 1.0

	# 3. Primer valle por debajo del umbral, bajando hasta su mínimo local
	var t := tau_min
	var found := false
	while t < tau_max:
		if d[t] < YIN_THRESHOLD:
			while t + 1 < tau_max and d[t + 1] < d[t]:
				t += 1
			found = true
			break
		t += 1
	if not found:
		return -1.0

	# 3b. Corrección de octava. Si el valle encontrado es un armónico (periodo
	# T/2 o T/3 en vez de T), en el periodo real T habrá un valle mucho más
	# profundo. Para la nota correcta, los valles en 2T y 3T son parecidos al de
	# T, así que exigir que sea claramente más profundo evita bajar de más.
	var best := t
	for k in [2, 3]:
		var cand := _local_min(d, t * k)
		if cand > 0 and d[cand] < d[best] * OCTAVE_RATIO:
			best = cand
	if best != t:
		octave_fixes += 1
		t = best

	# 4. Interpolación parabólica para afinar más allá de una muestra
	return sample_rate / _refine(d, t)


# Mínimo de d en un entorno de ±2 alrededor de center, o -1 si se sale del rango.
func _local_min(d: PackedFloat32Array, center: int) -> int:
	var lo := center - 2
	var hi := center + 2
	if lo < 1 or hi > tau_max - 1:
		return -1
	var best := lo
	for i in range(lo + 1, hi + 1):
		if d[i] < d[best]:
			best = i
	return best


func _refine(d: PackedFloat32Array, t: int) -> float:
	var a := d[t - 1]
	var b := d[t]
	var c := d[t + 1]
	var denom := a - 2.0 * b + c
	if absf(denom) < 1e-9:
		return float(t)
	return t + 0.5 * (a - c) / denom


func _median(values: Array[float]) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]


# ---------------------------------------------------------------- Notas

func _freq_to_midi(freq: float) -> float:
	return 69.0 + 12.0 * log(freq / A4) / log(2.0)


func _note_name(midi: int) -> String:
	var octave := floori(midi / 12.0) - 1
	return "%s%d" % [NOTE_NAMES[posmod(midi, 12)], octave]


func _describe_midi(midi: float) -> String:
	var nearest := roundi(midi)
	var cents := (midi - nearest) * 100.0
	return "%s  (%+.0f cents)" % [_note_name(nearest), cents]
