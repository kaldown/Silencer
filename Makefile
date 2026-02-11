.PHONY: libs clean-libs

libs:
	@echo "Fetching libraries for local development..."
	@mkdir -p Libs
	@if [ ! -d Libs/LibStub ]; then \
		git clone --depth 1 https://github.com/lua-wow/LibStub.git Libs/LibStub 2>/dev/null && \
		rm -rf Libs/LibStub/.git && \
		echo "  LibStub OK"; \
	else echo "  LibStub already exists"; fi
	@if [ ! -d Libs/CallbackHandler-1.0 ]; then \
		git clone --depth 1 https://github.com/zerosnake0/CallbackHandler-1.0.git Libs/CallbackHandler-1.0 2>/dev/null && \
		rm -rf Libs/CallbackHandler-1.0/.git && \
		echo "  CallbackHandler-1.0 OK"; \
	else echo "  CallbackHandler-1.0 already exists"; fi
	@if [ ! -d Libs/LibDataBroker-1.1 ]; then \
		git clone --depth 1 https://github.com/kaldown/LibDataBroker-1.1.git Libs/LibDataBroker-1.1 2>/dev/null && \
		rm -rf Libs/LibDataBroker-1.1/.git && \
		echo "  LibDataBroker-1.1 OK"; \
	else echo "  LibDataBroker-1.1 already exists"; fi
	@if [ ! -d Libs/LibDBIcon-1.0 ]; then \
		git clone --depth 1 https://github.com/kaldown/LibDBIcon-1.0.git Libs/LibDBIcon-1.0 2>/dev/null && \
		rm -rf Libs/LibDBIcon-1.0/.git && \
		echo "  LibDBIcon-1.0 OK"; \
	else echo "  LibDBIcon-1.0 already exists"; fi
	@echo "Done. Libs/ is gitignored - packager fetches fresh copies at release."

clean-libs:
	rm -rf Libs/
