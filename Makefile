CRYSTAL_FILES := $(shell find src -type f -name '*.cr')

.PHONY: larimar
larimar: ./bin/larimar

.PHONY: prompt
prompt: ./bin/prompt
	./bin/prompt

./bin/larimar: $(CRYSTAL_FILES)
	GC_DONT_GC=1 shards build larimar -p -s -Dpreview_mt

./bin/prompt: $(CRYSTAL_FILES)
	GC_DONT_GC=1 shards build prompt -Dpreview_mt
