clean:
	./clean-repo.sh

install:
	@yarn install

clean-%: clean $*