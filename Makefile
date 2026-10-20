CC ?= cc
CFLAGS ?= -O2 -std=gnu11 -Wall -Wextra
PREFIX ?= $(HOME)/.local

filetree: main.c
	$(CC) $(CFLAGS) -o $@ main.c -lm

install: filetree
	mkdir -p $(PREFIX)/bin
	install -m 755 filetree $(PREFIX)/bin/filetree

clean:
	rm -f filetree

.PHONY: install clean
