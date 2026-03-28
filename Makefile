CC = clang
# Must target x86_64 because the DS-720D TWAIN driver is x86_64 only (no arm64)
CFLAGS = -Wall -Wextra -O2 -fobjc-arc -arch x86_64
FRAMEWORKS = -framework Foundation -framework AppKit -framework TWAIN -framework Quartz
TARGET = dsscan
SRC = dsscan.m

.PHONY: all clean install

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) $(FRAMEWORKS) -o $@ $<

clean:
	rm -f $(TARGET)

install: $(TARGET)
	cp $(TARGET) /usr/local/bin/$(TARGET)
