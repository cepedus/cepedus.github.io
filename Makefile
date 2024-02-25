IMAGE_TAG := cepedus:test

clean:
	./clean-repo.sh

local:
	@docker build . -t ${IMAGE_TAG}
	@docker run --rm -a stdout -p 8080:8080 ${IMAGE_TAG}

clean-%: clean $*