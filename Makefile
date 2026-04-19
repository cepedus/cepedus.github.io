serve:
	@hugo server --buildDrafts --disableFastRender -p 1313

build:
	@hugo --gc --minify

update:
	@hugo mod get -u github.com/imfing/hextra

clean:
	@rm -rf public resources

.PHONY: serve build update clean