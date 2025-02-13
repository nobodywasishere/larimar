CRYSTAL_FILES := $(shell find src -type f -name '*.cr')

.PHONY: larimar
larimar: ./bin/larimar

.PHONY: ameba-ls
ameba-ls: ./bin/ameba-ls

.PHONY: prompt
prompt: ./bin/prompt
	./bin/prompt

.PHONY: ast_web
ast_web: ./bin/ast_web
	./bin/ast_web

./bin/larimar: $(CRYSTAL_FILES)
	GC_DONT_GC=1 shards build larimar -p -s -Dpreview_mt --release

./bin/ameba-ls: $(CRYSTAL_FILES)
	GC_DONT_GC=1 shards build ameba-ls -p -s -Dpreview_mt --release

./bin/prompt: $(CRYSTAL_FILES)
	GC_DONT_GC=1 shards build prompt -Dpreview_mt

./bin/ast_web: $(CRYSTAL_FILES)
	GC_DONT_GC=1 shards build ast_web -Dpreview_mt
