.PHONY: build unbuild

build/lib/%.js: lib/%.coffee
	mkdir -p build/lib
	cat "$<" | ./node_modules/.bin/coffee -b -c -s | ./node_modules/.bin/standard-format - > "$@"

build/package.json: package.json
	mkdir -p build
	cp "$<" "$@"
	if [ -d build/node_modules ]; then rm -R build/node_modules; fi
	npm install --prefix build --production

app: build/package.json \
     $(patsubst lib/%.coffee, build/lib/%.js, $(wildcard lib/*.coffee))
	sudo docker build ./

clean:
	rm -rf build
