#!/bin/sh
# Test speech in the app's own voice, the polyglot snepssen (apple/tcsay),
# for tcrun to interpret into another language. Unlike the macOS voices of
# make-samples.sh, this is the voice the app speaks with, so a run also shows
# how legible it is to speech recognition. German, French, Spanish and Italian
# are make-samples.sh's lines; the others say the German one's news in their
# own words, each with its own way of saying half past ten. Writes
# samples/snep_<lang>.wav and, beside it, the text without its silences.
set -eu
cd "$(dirname "$0")/.."
say_to() { (cd apple && swift run -q tcsay --lang "$1" --out "../samples/snep_$1.wav" "$2"); }

say_to en "So, I just wanted to say [[slnc 800]] that tomorrow we don't start at nine, [[slnc 600]] but at half past ten. [[slnc 300]] The reason is that the train from Manchester [[slnc 900]] is cancelled because of engineering works. [[slnc 1200]] Anyone who can should maybe come by car, and anyone without a car, [[slnc 500]] please let me know. [[slnc 1500]] Thanks."

say_to pl "No więc, [[slnc 700]] chcę tylko powiedzieć, że jutro zaczynamy [[slnc 900]] nie o dziewiątej, tylko o wpół do jedenastej. [[slnc 400]] Pociąg z Krakowa jest odwołany [[slnc 800]] z powodu remontu torów. [[slnc 1200]] Kto może, niech przyjedzie samochodem, a kto nie ma samochodu, [[slnc 500]] niech do mnie zadzwoni. [[slnc 1500]] Dzięki."

say_to hu "Szóval, [[slnc 700]] csak azt akartam mondani, hogy holnap [[slnc 900]] nem kilenckor kezdünk, hanem fél tizenegykor. [[slnc 400]] A budapesti vonat ugyanis [[slnc 800]] pályafelújítás miatt nem jár. [[slnc 1200]] Aki tud, jöjjön inkább autóval, aki pedig nem, [[slnc 500]] az szóljon nekem. [[slnc 1500]] Köszönöm."

say_to de "Also, ich wollte eigentlich [[slnc 900]] nur kurz sagen, dass wir [[slnc 1100]] morgen nicht um neun, sondern erst [[slnc 700]] um halb elf anfangen. [[slnc 300]] Der Grund ist, dass der Zug aus München [[slnc 1000]] wegen Bauarbeiten ausfällt. [[slnc 1500]] Ähm, [[slnc 600]] wer kann, sollte vielleicht [[slnc 800]] mit dem Auto kommen, und wer kein Auto hat, [[slnc 500]] meldet sich bitte bei mir. [[slnc 1800]] Danke."

say_to nl "Nou, [[slnc 700]] ik wilde eigenlijk even zeggen dat we morgen [[slnc 900]] niet om negen uur beginnen, maar pas om half elf. [[slnc 400]] De trein uit Utrecht rijdt niet [[slnc 800]] vanwege werkzaamheden aan het spoor. [[slnc 1200]] Wie kan, komt misschien beter met de auto, en wie geen auto heeft, [[slnc 500]] laat het me even weten. [[slnc 1500]] Bedankt."

say_to fr "Je pense que le projet avance bien mais il faudrait quand même vérifier les chiffres du dernier trimestre parce que les résultats ne correspondent pas tout à fait à ce que nous avions prévu au départ et je voudrais vraiment qu'on en parle lors de la prochaine réunion avec toute l'équipe y compris les collègues de Lyon qui ne sont pas encore au courant."

say_to es "Buenos días a todos. Hoy vamos a hablar del nuevo horario de la biblioteca. A partir del lunes abrimos a las ocho de la mañana y cerramos a las diez de la noche. Los fines de semana el horario no cambia. Si tenéis preguntas, podéis escribirme por correo."

say_to it "Allora, il treno parte alle... [[slnc 700]] no, scusate, [[slnc 400]] il treno parte alle sette e un quarto, non alle sette. [[slnc 1200]] Quindi ci vediamo in stazione [[slnc 600]] verso le sette meno cinque."
