---
title: "Go: JSON をゆるふわに扱ってみた"
emoji: "🌟"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ["go", "json"]
published: false
---

# 作ったもの
https://github.com/hayas1/go-fluffy-json

# 背景
GoでJSONをパースするとき、構造体にマッピングして使うことが多いです。
```go
	type Animal struct {
		Name  string `json:"name"`
		Order string `json:"order"`
	}
	var animal Animal
	err := json.Unmarshal([]byte(`{"name": "Platypus", "order": "Monotremata"}`), &animal)
	if err != nil {
		fmt.Println("error:", err)
	}
	fmt.Printf("%+v", animal) // Output: {Name:Platypus Order:Monotremata}
```

この方法は、プログラムで扱いたいJSONがコンパイル時に決まっている場合は非常に有用であるものの、コンパイル時に決まらない場合は `interface{}` に Unmarshal して、例えば `map[string]interface{}` などの形で処理することになります。
```go
	var animal map[string]interface{}
	err := json.Unmarshal([]byte(`{"name": "Platypus", "order": "Monotremata"}`), &animal)
	if err != nil {
		fmt.Println("error:", err)
	}
	fmt.Printf("%+v", animal) // Output: map[name:Platypus order:Monotremata]
```

GoではこのようにしてJSONをかっちり扱ったりゆるふわに扱ったりするわけです。しかし、ここで一つ問題があります。 `interface{}` はあまりにもゆるふわすぎるということです。

[JSON](https://www.json.org/)である以上、`object`, `array`, `string`, `number`, `"true", "false"`, `"null"` の要素から構成されるということは決まっているわけですが、 `interface{}` ではそれを表現できず、使うときに毎回キャストしたり type switch したりしないといけません。しかし、ここに罠があり、たとえば `interface{}` に Unmarshal された JSON では、数値は全て `float64` になるので、`int` に type switch しようとしても、コンパイルは通るのに実行時にはその case は実行されません。
```go
	var number map[string]interface{}
	err := json.Unmarshal([]byte(`{"number": 16}`), &number)
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
