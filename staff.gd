class_name Staff
extends Node2D
## Pentagrama en clave de sol que muestra una nota (redonda).
## El origen del nodo es el extremo izquierdo de la línea superior.

const S := 20.0                    # Separación entre líneas del pentagrama (todo escala con esto)
const WIDTH := 360.0               # Largo del pentagrama
const LINE_WIDTH := 2.0
const PAPER_MARGIN := Vector2(24, 90)  # Margen del "papel" (vertical amplio para las líneas adicionales)
const NOTE_X := 230.0              # Posición horizontal de la nota

# Clave de sol: se dibuja con el carácter Unicode 𝄞 de una fuente del sistema.
# Cada fuente coloca el glifo un poco distinto: ajusta estos dos valores hasta
# que el rizo central de la clave rodee la segunda línea empezando por abajo.
const CLEF_FONT_SIZE := 86
const CLEF_OFFSET := Vector2(6, 14)

const PAPER_COLOR := Color(0.98, 0.97, 0.93)
const INK := Color(0.08, 0.08, 0.08)

# Para cada clase de nota (Do=0 ... Si=11): [posición en la escala natural, ¿sostenido?]
# Do=0 Re=1 Mi=2 Fa=3 Sol=4 La=5 Si=6
const PITCH_CLASS := [
	[0, false], [0, true], [1, false], [1, true], [2, false], [3, false],
	[3, true], [4, false], [4, true], [5, false], [5, true], [6, false],
]
# Mi4 (línea inferior en clave de sol) como número diatónico: octava 4 * 7 + Mi(2)
const BOTTOM_LINE_DIATONIC := 30

var midi := -1
var note_color := INK
var music_font: SystemFont


func _ready() -> void:
	music_font = SystemFont.new()
	# Primera que exista en el sistema; si ninguna tiene el glifo, Godot busca otra fuente del sistema
	music_font.font_names = PackedStringArray(["Segoe UI Symbol", "Noto Music", "FreeSerif", "Bravura Text"])


func set_note(new_midi: int) -> void:
	midi = new_midi
	note_color = INK
	queue_redraw()


func set_note_color(color: Color) -> void:
	if color != note_color:
		note_color = color
		queue_redraw()


func _draw() -> void:
	# Papel
	draw_rect(Rect2(-PAPER_MARGIN, Vector2(WIDTH, 4 * S) + 2 * PAPER_MARGIN), PAPER_COLOR)

	# Cinco líneas
	for i in 5:
		draw_line(Vector2(0, i * S), Vector2(WIDTH, i * S), INK, LINE_WIDTH)

	# Clave de sol (la línea de Sol4 es la segunda desde abajo: y = 3S)
	draw_string(music_font, Vector2(CLEF_OFFSET.x, 3 * S + CLEF_OFFSET.y), "𝄞",
			HORIZONTAL_ALIGNMENT_LEFT, -1, CLEF_FONT_SIZE, INK)

	if midi < 0:
		return

	var pc: Array = PITCH_CLASS[posmod(midi, 12)]
	var octave := floori(midi / 12.0) - 1
	var step: int = octave * 7 + pc[0] - BOTTOM_LINE_DIATONIC  # 0 = línea inferior, 1 = primer espacio...
	var y := _step_y(step)

	# Líneas adicionales: por debajo (Do4 = paso -2) y por encima (La5 = paso 10)
	var s := -2
	while s >= step:
		_draw_ledger(s)
		s -= 2
	s = 10
	while s <= step:
		_draw_ledger(s)
		s += 2

	# Sostenido
	if pc[1]:
		draw_string(music_font, Vector2(NOTE_X - 2.4 * S, y + 0.75 * S), "♯",
				HORIZONTAL_ALIGNMENT_LEFT, -1, int(2.2 * S), note_color)

	_draw_whole_note(Vector2(NOTE_X, y))


# Paso diatónico -> coordenada y (cada paso es media separación de línea)
func _step_y(step: int) -> float:
	return 4 * S - step * S * 0.5


func _draw_ledger(step: int) -> void:
	var y := _step_y(step)
	draw_line(Vector2(NOTE_X - 1.4 * S, y), Vector2(NOTE_X + 1.4 * S, y), INK, LINE_WIDTH)


# Redonda: elipse rellena con un hueco ovalado inclinado
func _draw_whole_note(center: Vector2) -> void:
	var r := 0.55 * S
	draw_set_transform(center, 0.0, Vector2(1.45, 1.0))
	draw_circle(Vector2.ZERO, r, note_color)
	draw_set_transform(center, -0.6, Vector2(0.75, 1.05))
	draw_circle(Vector2.ZERO, r * 0.62, PAPER_COLOR)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
