ROOT = ../..
PROJECT = whistle

SOURCES = src/kazoo_transform.erl src/*.erl src/api/*.erl

COMPILE_MOAR = src/kz_mime.erl
CLEAN_MOAR = clean-generated

# Mimetypes module generator.

GEN_URL = http://svn.apache.org/repos/asf/httpd/httpd/trunk/docs/conf/mime.types
GEN_FILE = mime.types
GEN_SRC = src/kz_mime.erl.src
GEN_OUT = src/kz_mime.erl

all: compile

include $(ROOT)/make/kz.mk

clean-generated:
	$(if $(wildcard src/kz_mime.erl), rm src/kz_mime.erl)

src/kz_mime.erl: src/kz_mime.erl.src
	@wget -qO $(GEN_FILE) $(GEN_URL)
	@cat $(GEN_SRC) \
		| head -n `grep -n "%% GENERATED" $(GEN_SRC) | cut -d : -f 1` \
		> $(GEN_OUT)
	@echo "from_extension(Ext) when not is_binary(Ext) -> from_extension(wh_util:to_binary(Ext));" >> $(GEN_OUT)
	@echo "from_extension(<<$$., Ext/binary>>) -> from_extension(Ext);" >> $(GEN_OUT)
	@cat $(GEN_FILE) \
		| grep -v ^# \
		| awk '{for (i=2; i<=NF; i++) if ($$i != "") { \
			print "from_extension(<<\"" $$i "\">>) -> <<\"" $$1 "\">>;"}}' \
		| sort \
		| uniq -w 25 \
		>> $(GEN_OUT)
	@echo "from_extension(_) -> <<\"application/octet-stream\">>." >> $(GEN_OUT)
	@echo "" >> $(GEN_OUT)
	@cat $(GEN_FILE) \
		| grep -v ^# \
		| awk '{\
			printf("to_extensions(<<\"%s\">>) -> [", $$1); \
			for (i=2; i<=NF; i++) \
				if ($$i != "") { \
					if (i >= 3){printf(",")} \
					printf("<<\"%s\">>",  $$i) \
				}\
			print "];" \
			}' \
		| sort \
		>> $(GEN_OUT)
	@echo "to_extensions(_) -> [<<>>]." >> $(GEN_OUT)
	@cat $(GEN_SRC) \
		| tail -n +`grep -n "%% GENERATED" $(GEN_SRC) | cut -d : -f 1` \
		>> $(GEN_OUT)

