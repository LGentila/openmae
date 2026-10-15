#!/bin/zsh
# Generates the spoken test phrases used by voice-cli, with macOS's built-in voices.
# They are synthetic: fine for timing and logic, not for judging recognition accuracy.
# Usage: zsh scripts/make-test-audio.sh   → writes measurements/audio/*.wav (16 kHz mono)
set -eu
OUT=measurements/audio
mkdir -p $OUT
s() { say -v "$1" -o "$OUT/$2.wav" --data-format=LEI16@16000 "$3"; }

# A six-turn conversation (turn 4 has a pause in the middle: the engine must not answer too early).
s Thomas   01-recette   "Bonjour ! Tu peux me donner une idée de recette rapide pour ce soir avec des courgettes ?"
s Thomas   02-sans-four "Et sans four, ça marche aussi ?"
s Thomas   03-ciel      "Explique-moi en deux phrases pourquoi le ciel est bleu."
s Thomas   04-sortie    "Je cherche une idée de sortie pour samedi. [[slnc 350]] Plutôt en extérieur."
s Samantha 05-english   "Hey, can you tell me a fun fact about octopuses?"
s Thomas   06-memoire   "Merci ! Et tu te souviens de ce que je voulais cuisiner ce soir ?"

# Interruption test: a question with a long answer, then the user talking over it.
s Thomas   10-histoire  "Raconte-moi une longue histoire de pirates, avec beaucoup de détails."
s Thomas   11-stop      "Attends, arrête. Parle-moi plutôt de la météo."
ls $OUT
