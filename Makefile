.PHONY: build
build:
	GC_DONT_GC=1 shards build -p -s -Dpreview_mt
