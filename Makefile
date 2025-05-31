local:
	@npx quartz build --serve

ci:
	@npm run format
	@npm ci
	@npm run check
	@npm test
	@npx quartz build --bundleInfo -d docs