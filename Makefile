local:
	@npx quartz build --serve

ci:
	@npm ci
	@npm run check
	@npm test
	@npx quartz build --bundleInfo -d docs