SWIFTC = swiftc
FLAGS = -O -framework AppKit -framework Foundation
TARGET = build/lol-guard
SRC = Sources/main.swift

.PHONY: all clean test

all: $(TARGET)

$(TARGET): $(SRC)
	@mkdir -p build
	$(SWIFTC) $(FLAGS) $(SRC) -o $(TARGET)
	@strip $(TARGET)

clean:
	rm -rf build

test: $(TARGET)
	./$(TARGET) --status --dry-run
