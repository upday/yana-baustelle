File.open("Makefile", "w") do |makefile|
  makefile.puts <<-MAKEFILE
.PHONY: all

all: gradle

clean:

install: gradle

gradle:
\twhich gradle || (echo "Gradle not found" && exit 1)
\texit 1
  MAKEFILE
end
