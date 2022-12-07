serve:
	@rm -rf _site .sass-cache .jekyll-metadata
	@python tag_generator.py
	@docker compose up