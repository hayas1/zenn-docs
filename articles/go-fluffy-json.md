---
title: "Go: JSON をゆるふわに扱ってみた"
emoji: "🌟"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ["go", "json"]
published: false
---

# 作ったもの
https://github.com/hayas1/go-fluffy-json

https://pkg.go.dev/github.com/hayas1/go-fluffy-json
Goで書くとPublicなGitHubに置いておくとほぼ自動でドキュメントを生成してくれるの初めて知りましたがとても便利でした。あとGoはGitHubに置いておくだけでimportできるので、この記事に貼ってあるコードは[playground](https://go.dev/play/)にコピペするだけで動かせて、それも便利でした。

# 背景
GoでJSONをパースするとき、構造体にマッピングして使うことが多いです。
```go
	type Animal struct {
		Name  string `json:"name"`
		Order string `json:"order"`
	}
	target := `{"name": "Platypus", "order": "Monotremata"}`
	var animal Animal
	err := json.Unmarshal([]byte(target), &animal)
	if err != nil {
		fmt.Println("error:", err)
	}
	fmt.Printf("%+v", animal) // Output: {Name:Platypus Order:Monotremata}
```

この方法は、プログラムで扱いたいJSONがコンパイル時に決まっている場合は非常に有用であるものの、コンパイル時に決まらない場合は `interface{}` に Unmarshal して、例えば `map[string]interface{}` などの型で処理することになります。
```go
	target := `{"name": "Platypus", "order": "Monotremata"}`
	var animal map[string]interface{}
	err := json.Unmarshal([]byte(target), &animal)
	if err != nil {
		fmt.Println("error:", err)
	}
	fmt.Printf("%+v", animal) // Output: map[name:Platypus order:Monotremata]
```

GoではこのようにしてJSONをかっちり扱ったりゆるふわに扱ったりするわけです。しかし、ここで一つ問題があります。 `interface{}` はあまりにもゆるふわすぎるということです。

[JSON](https://www.json.org/)である以上、`object` `array` `string` `number` `"true"` `"false"` `"null"` の要素から構成されるということは決まっているわけですが、 `interface{}` ではそれを表現できず、使うときに毎回キャストしたり type switch したりしないといけません。しかし、ここに罠があり、たとえば `interface{}` に Unmarshal された JSON では[数値は全て `float64` になる](https://pkg.go.dev/encoding/json#Unmarshal)ので、`int` に type switch しようとしても、コンパイルは通るのに実行時には `case int:` の部分は実行されません。
```go
    target := `{"number": 16}`
	var number map[string]interface{}
	err := json.Unmarshal([]byte(target), &number)
	if err != nil {
		fmt.Println("error:", err)
	}
	switch d := number["number"].(type) {
	case int:
		fmt.Println(d)
	default:
		fmt.Println("not a number") // Output: not a number
	}
```

ちなみに Rust では [serde_json のライブラリに実装されている `Value` の enum](https://docs.rs/serde_json/latest/serde_json/enum.Value.html) を使ってゆるふわに JSON をパースできるので、このような困りごとは発生しないです(Goでもこういうのがあったらすみません、把握していませんでした 🙏)。というわけで、Goでこの `Value` ような enum ライクなものを実装してみたい、というのがこの記事で扱う内容です。

# 使い方
こんな感じで使えるようになりました。[ドキュメント](https://pkg.go.dev/github.com/hayas1/go-fluffy-json#pkg-examples)にもExampleが載っています。無事 `case int:` と書くとコンパイルエラーになることが達成できました。しかし、`encoding/json`の `Unmarshaler` を実装している都合もあり、case に書く部分がポインタになってしまっています。これは改善の余地があるかもしれないです。
```go
	target := `{"number":16}`
	var number map[string]fluffyjson.RootValue
	if err := json.Unmarshal([]byte(target), &number); err != nil {
		panic(err)
	}

	switch d := number["number"].JsonValue.(type) {
	// case int:
	// 	panic("fail to compile: int does not implement JsonValue interface")
	case *fluffyjson.Number:
		fmt.Println(*d) // Output: 16
	default:
		panic("not object")
	}
```

さて、JSON をゆるふわに扱う以上、ネストされた位置にある要素へのアクセスや、型のキャストが課題になります。そういうときに使うことができるメソッドも用意しています。 `AccessAsString` のようなメソッドでネストされた位置へのアクセスと型へのキャストを同時に解決します。[serde_jsonのValueでも採用](https://docs.rs/serde_json/latest/serde_json/enum.Value.html#method.pointer)されている、[JSON Pointer (RFC6901)](https://tools.ietf.org/html/rfc6901) を採用しています。
```go
	target := `{"deep":{"nested":{"json":{"value":["hello","world"]}}}}`
	var value fluffyjson.RootValue
	if err := json.Unmarshal([]byte(target), &value); err != nil {
		panic(err)
	}

	pointer, err := fluffyjson.ParsePointer("/deep/nested/json/value/1")
	if err != nil {
		panic(err)
	}

	world, err := value.AccessAsString(pointer)
	if err != nil {
		panic(err)
	}
	fmt.Println(world) // Output: world
```

工夫ポイントとして、`AccessAsString` のようなメソッドは可変長引数を受け取っており、引数を渡さない場合はJSONのルートの要素を `string` へキャストします。ルートが `object` だったりするとエラーが返ります。可変長引数なので、JSON PointerのParseをせずとも1要素ずつ渡すこともできますが、intやstringをそのままは受け取れず、そのために定義した型でラップする必要はあり、これも改善の余地があるのかもしれないです。
```go
	target := `{"deep":{"nested":{"json":{"value":["hello","world"]}}}}`
	var value fluffyjson.RootValue
	if err := json.Unmarshal([]byte(target), &value); err != nil {
		panic(err)
	}

	world, err := value.AccessAsString(
		fluffyjson.KeyAccess("deep"), fluffyjson.KeyAccess("nested"), fluffyjson.KeyAccess("json"), fluffyjson.KeyAccess("value"), fluffyjson.IndexAccess(1),
	)
	if err != nil {
		panic(err)
	}
	fmt.Println(world) // Output: world
```

一応 Visitor パターンも実装しており Unmarshal した JSON を 深さ優先探索したり幅優先探索したりもできます。簡単に使うために、ただノードをその順番で返すイテレータを得る `DepthFirst` や `BreadthFirst` などのメソッドも用意しています。
```go
	target := `[[[1,2],[3,4]],[[5,6],[7,8]]]`
	var value fluffyjson.RootValue
	if err := json.Unmarshal([]byte(target), &value); err != nil {
		panic(err)
	}

	var sum func(v fluffyjson.JsonValue) int
	sum = func(v fluffyjson.JsonValue) int {
		switch t := v.(type) {
		case *fluffyjson.Array:
			s := 0
			for _, vv := range *t {
				s += sum(vv)
			}
			return s
		case *fluffyjson.Number:
			return int(*t)
		default:
			panic("not array or number")
		}
	}
	results := make([]int, 0, 15)
	for _, v := range value.DepthFirst() {
		results = append(results, sum(v))
	}
	fmt.Println(results) // Output: [36 10 3 1 2 7 3 4 26 11 5 6 15 7 8]
```
