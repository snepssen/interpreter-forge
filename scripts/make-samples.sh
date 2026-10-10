#!/bin/sh
# Synthetic test speech from the macOS voices. Clean and fluent by nature, so
# hesitation is written in with [[slnc ms]] silences. Real recordings of real
# people are the test that matters; these exercise the plumbing and the rules.
set -eu
cd "$(dirname "$0")/.."
mkdir -p samples

say_to() { say -v "$1" -o "samples/$2.wav" --data-format=LEI16@16000 "$3"; echo "samples/$2.wav"; }

# Verb-final German with pauses inside the clause: cutting on pauses alone
# would ship "dass wir" long before "anfangen" arrives.
say_to Anna de_halting "Also, ich wollte eigentlich [[slnc 900]] nur kurz sagen, dass wir [[slnc 1100]] morgen nicht um neun, sondern erst [[slnc 700]] um halb elf anfangen. [[slnc 300]] Der Grund ist, dass der Zug aus München [[slnc 1000]] wegen Bauarbeiten ausfällt. [[slnc 1500]] Ähm, [[slnc 600]] wer kann, sollte vielleicht [[slnc 800]] mit dem Auto kommen, und wer kein Auto hat, [[slnc 500]] meldet sich bitte bei mir. [[slnc 1800]] Danke."

# One French sentence that never stops: exercises the forced cut.
say_to "Flo (French (France))" fr_runon "Je pense que le projet avance bien mais il faudrait quand même vérifier les chiffres du dernier trimestre parce que les résultats ne correspondent pas tout à fait à ce que nous avions prévu au départ et je voudrais vraiment qu'on en parle lors de la prochaine réunion avec toute l'équipe y compris les collègues de Lyon qui ne sont pas encore au courant."

# Fluent Spanish, ordinary sentence breaks.
say_to "Flo (Spanish (Spain))" es_fluent "Buenos días a todos. Hoy vamos a hablar del nuevo horario de la biblioteca. A partir del lunes abrimos a las ocho de la mañana y cerramos a las diez de la noche. Los fines de semana el horario no cambia. Si tenéis preguntas, podéis escribirme por correo."

# Italian with a false start and a self-correction.
say_to Alice it_restart "Allora, il treno parte alle... [[slnc 700]] no, scusate, [[slnc 400]] il treno parte alle sette e un quarto, non alle sette. [[slnc 1200]] Quindi ci vediamo in stazione [[slnc 600]] verso le sette meno cinque."
