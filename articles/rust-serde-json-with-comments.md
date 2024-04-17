---
title: "Rust: serde 互換の JSON with comments パーサーを作ってみた"
emoji: "😽"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ["rust", "serde", "jsonc"]
published: true
---

# 作ったもの
https://github.com/hayas1/json-with-comments/blob/v0.1.5/README.md#json-with-comments

完成はしていないですが、一旦まともに使うことができるぐらいにはなってきたので、やったことを残すべくこの記事に書いていきます

なお、まだやれてないことも書いておくと↓のような感じです
- パフォーマンスのチューニング、ベンチマークテスト
- raw_value などの serde_json にあるような feature の実装
- commentをパースしてデシリアライズできるようにする(serdeの制限であまり現実的でないかもしれない)

# 使い方
使い方はおよそREADMEに書いてある通りですが、 [serde_json](https://github.com/serde-rs/json) とだいたい同じように使えます。
(まだ実装できてない機能もいくつかあり、また、互換性を持たせることが目的ではないので細かいインターフェースもところどころ異なります)
```toml:Cargo.toml
[dependencies]
json_with_comments = { git = "https://github.com/hayas1/json-with-comments" }
```

## `Deserialize` を実装している型へのデシリアライズ
https://github.com/hayas1/json-with-comments/blob/v0.1.5/README.md#parse-jsonc-as-typed-struct

JSONC からのデシリアライズはこんな感じです。コメントがついていたり trailing comma があったりしてもパースできる以外はだいたい serde_json と同じですね
```rust
use serde::Deserialize;
#[derive(Deserialize)]
struct Person<'a> {
    name: &'a str,
    address: Address<'a>,
}
#[derive(Deserialize)]
struct Address<'a> {
    street: &'a str,
    number: u32,
}

let json = r#"{
    "name": "John Doe", // John Doe is a fictional character
    "address": {
        "street": "Main",
        "number": 42, /* trailing comma */
    },
}"#;

let data: Person = json_with_comments::from_str(json).unwrap();
assert!(matches!(
    data,
    Person {
        name: "John Doe",
        address: Address { street: "Main", number: 42 }
    }
));
```

## `Value` へのデシリアライズ
JSONCをデシリアライズしたい型が決まってない時は `Value` を使うことができます。 `Value` は `[]` を使ってインデックスアクセスができたり、その他いくつか便利なメソッドを持っています。 `jsonc!` マクロを使って `Value` を作ることもできます。このあたりも serde_json とだいたい同じですね。
```rust
use json_with_comments::{from_str, Value, jsonc};

let json = r#"{
    "name": "John Doe", // John Doe is a fictional character
    "address": {
        "street": "Main",
        "number": 42, /* trailing comma */
    },
}"#;

let data: Value = from_str(json).unwrap();
assert_eq!(data["name"], Value::String("John Doe".into()));
assert_eq!(data["address"]["street"], Value::String("Main".into()));
assert_eq!(data.query("address.number"), Some(&42.into()));
assert_eq!(data, jsonc!({ "name": "John Doe", "address": { "street": "Main", "number": 42 }}));
```

## `Serialize` を実装している型からのシリアライズ
データを JSONC へシリアライズすることもできます。これも serde_json とだいたい同じですね
```rust
use serde::Serialize;
#[derive(Serialize)]
struct Person<'a> {
    name: &'a str,
    address: Address<'a>,
}
#[derive(Serialize)]
struct Address<'a> {
    street: &'a str,
    number: u32,
}

let person = Person {
    name: "John Doe",
    address: Address {
        street: "Main",
        number: 42,
    },
};

let minify = r#"{"name":"John Doe","address":{"street":"Main","number":42}}"#;
assert_eq!(json_with_comments::to_string(&person).unwrap(), minify);

let pretty = r#"{
  "name": "John Doe",
  "address": {
    "street": "Main",
    "number": 42,
  },
}"#;
assert_eq!(json_with_comments::to_string_pretty(&person).unwrap(), pretty);
```

## serde_json の `Value` との相互変換
さらに、 `Value` を、 `Serialize` や `Deserialize` を実装している型へシリアライズしたりデシリアライズしたりすることもできます。実はこれも serde_json とだいたい同じです。今回はこれを使って、 `json_with_comments::Value` と `serde_json::Value` の相互変換を実現しています。
```rust
use serde::{Deserialize, Serialize};
use serde_json::json;
use json_with_comments::jsonc;

let (json, jsonc) = (json!({"name": "John Doe","age": 30}), jsonc!({ "name": "John Doe", "age": 30 }));

// serde_json::Value -> json_with_comments::Value
assert_eq!(json_with_comments::to_value(&json).unwrap(), jsonc);
assert_eq!(serde_json::from_value::<json_with_comments::Value>(json.clone()).unwrap(), jsonc);

// json_with_comments::Value -> serde_json::Value
assert_eq!(json_with_comments::from_value::<serde_json::Value>(&jsonc).unwrap(), json);
assert_eq!(serde_json::to_value(jsonc.clone()).unwrap(), json);
```


# 実装について
細かいことなので、わざわざ書いても、という気もしますが、せっかくなので書いてみます。

## serde の抽象化に従う
### Deserialize
serde において Deserialize の登場人物は大きく 3 人です。
- `Deserialize` トレイト: `Deserializer` トレイトによってデシリアライズできる型のことです。ほぼマーカーみたいなものです。
- `Deserializer` トレイト: 実際にデシリアライズする人のことです。パーサーみたいなものです。
- `Visitor` トレイト: パースされた値を実際にRustの値として対応させる人です。
  - 例えば `100` という JSON を `usize` にデシリアライズしたいとして、`usize`の変数に実際に値を代入する部分をやっているイメージです

つまり、今回実装していくのは `Deserializer` トレイトが主軸になり、あとは serde がよしなにやってくれるということです。 `Deserializer` トレイトはかなりたくさんのメソッドを要求していて、たとえば `deserialize_any` や `deserialize_bool` があります。ちなみに、これらのメソッドが引数として `Visitor` をもらっている、いわゆる Visitor パターンになっています。`deserialize_bool` は今読んでいる文字列が `true` であれば `true` を、 `false` であれば `false` を、 `Visitor` に渡せばいいだけなので実装が比較的楽です。一方で `deserialize_any` などはそうもいかず、例えば今読んでいる文字列が `{` であれば Object(いわゆる Map) のパースが必要です。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/de/access/jsonc.rs#L58-L91

↑に載せた実装の  `deserialize_any` では今読んでいる文字列が `{` だったときは `Deserializer` トレイトで同じく要求されている `deserialize_map` メソッドを呼んでいます。 `deserialize_map` メソッドでは↓のように、 `{` の中身のパースを `MapDeserializer` 構造体に任せており、これは serde の `MapAccess` トレイトを実装したものになっています。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/de/access/jsonc.rs#L276-L290

`MapAccess` トレイトが要求しているメソッドは幸い(？) 2 つだけで、 `next_key_seed` と `next_value_seed` だけです。 `next_key_seed` が `None` を返せば Map は終わりという、 Iterator のようなインターフェースを備えています。 `next_value_seed` では、またまた JSON が入れ子になる可能性がありますが、それに関しての実装は実は簡単で、上で今まで作ってきたような `Deserializer` に処理を投げればよいです。逆にkeyの方が(JSONでは文字列だけという制限があるため)今まで作った `Deserializer` にまるまる処理を投げることができずむしろ大変です(専用の `Deserializer` を用意しています…)。それさえ済めば、あとは `:` による key と value の区切りや、 `,` による key-value の区切り、 `}` による Object の終わりなどを処理すればよいぐらいです。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/de/access/map.rs#L26-L59

↑では Object の入れ子の処理について書きましたが、 Array についても似たような実装をやっていく必要があります。また、各種の数値型や struct や enum のデシリアライズについても実装していく必要があったり、ここでは触れませんがなかなか多くのコードが必要になってきます。

### Serialize
serde において Serialize は Visitor パターンではないので、登場人物は大きく 2 人と言って差し支えないと思います。こっちは Deserialize よりはシンプルです。
- `Serialize` トレイト: `Serializer` トレイトによってシリアライズできる型のことです。
  - `Deserialize` トレイトと同じくほぼマーカーみたいなものです。
- `Serializer` トレイト: 実際にシリアライズをやる人のことです。
  - `SerializeSeq` や `SerializeMap` などのトレイトに、入れ子部分のシリアライズを任せたりはしています。

Serialize についても Deserialize と同じく、今回実装していくのは `Serializer` トレイトが主軸になり、あとは serde がよしなにやってくれます。このトレイトは、 `SerializeMap` などの入れ子をシリアライズする型を Associated Type でたくさん要求していて、`serialize_bool` や `serialize_map` などこちらもたくさんのメソッドを要求しています。 `Serializer` については特に Visitor パターンという感じでもなく、各メソッドがそれぞれ実際の値を渡されるので、それを文字列にしていく処理をゴソゴソと書いていく形です。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/ser/access/jsonc.rs#L25-L54

`serialize_map` などのメソッドでは、処理を `SerializeMap` に投げています。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/ser/access/jsonc.rs#L172-L174

`SerializeMap` のやることも、 Deserialize の `MapAccess` 同様です。value部分の入れ子をおおもとの `Serializer` に投げたり、key部分には専用の `Serializer` を用意したりします。`:` による key と value の区切り、 `,` による key-value の区切り、 `}` による Object の終わりなどを文字列として書き込んでいきます(↓のコードでは、minify format の JSON と pretty format の JSON どちらにも出力できるための抽象化が入っているのでリテラルとして `:` や `,` や `}` が直接ここのコードに現れてはないですが)。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/ser/access/map.rs#L27-L58

Serialize は Deserialize よりシンプルではありますが、入れ子を処理するためのトレイトが、`SerializeSeq`, `SerializeTuple`, `SerializeTupleStruct`, `SerializeTupleVariant`, `SerializeMap`, `SerializeStruct`, `SerializeStructVariant` の 7 個ほどあったりするので、なんだかんだで Deserialize と同じくらいの量のコードを書くことになります。(`SerializeTuple` の処理は実質 `SerializeSeq` に投げれたりということもあって全部が全部実装を書いていかないといけないわけではない)

## `Value` の Serialize と Deserialize
文字列 ↔ Rustの値 だけでなく、 `Value` ↔ Rustの値 についても Serialize と Deserialize で抽象化されるため、その実装もあります。はじめに `Value` について書いておくと、これはその実 `Map` や `String` といったJSONの値を表す enum になっています。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/value.rs#L63-L100

つまり、パーサーが「今読んでいる文字列」に応じて Rust の値へデシリアライズするのと同様に、`Value` の「今見ている値」に応じて Rust の値へデシリアライズできます。そして、Rust の値を JSON 文字列にシリアライズできるのと同様に、 Rust の値を `Value` へシリアライズできます。
そのための実装が [value/de](https://github.com/hayas1/json-with-comments/tree/v0.1.5/src/value/de) や [value/ser](https://github.com/hayas1/json-with-comments/tree/v0.1.5/src/value/ser) に書いてあります
https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/value/de/deserializer.rs#L59-L91
https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/value/ser/serializer.rs#L29-L50

今回作った `json-with-comments` の `Value` と `serde_json` の `Value` を相互変換する仕組みは、これに乗っかっています。

## macro の実装
主にはデシリアライズしたい型が定まっていない場合などに使う `Value` の列挙型ですが、文字列をパースとかしなくても作りたいですよね。
そのために、 `serde_json` では `Value` を簡単に作ることができる `json!` macro が用意されていて、今回作った `json-with-comments` でも同様に `Value` を簡単に作ることができる `jsonc!` macro を用意しています。↓みたいな感じでお手軽に使うことができます
```rust
let value = jsonc!({"key": "value", "null": null});
```

https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/value/macros.rs#L62-L81
Rust の macro (ここでは[宣言的マクロ](https://doc.rust-jp.rs/book-ja/ch19-06-macros.html)のことです) は基本的に引数を解析して `block`, `expr`, `tt` などの[マッチする構造](https://doc.rust-lang.org/reference/macros-by-example.html#metavariables)に応じてコード生成して置き換える、といったことをします。`expr` は式のことで、`tt` はトークンツリーのことです。↑のコードだと、
- `[` `]` で囲われていたら `array!` macro に処理を投げる
- `{` `}` で囲われていたら `object!` macro に処理を投げる
- null だったら `Value::Null` を返す
- `expr` だったら `Value::from` を使って `Value` を生成する

というイメージです。 `null` という文字列は Rust 的には式ではないので `expr` にはマッチしないといったミソがあります。

https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/value/macros.rs#L151-L224
`object!` macro が `array!` macro に比べて実装がちょっと大変だった話があるので、簡単に紹介します

`object!` macro がやりたいことは、↓のようになります。
- `key: value,` の形を見つけて、 `(key, value)` の tuple にする
- `key: value,` の形がなくなるまで繰り返す
- すると、 `[(key, value), ...]` のようなリストが作られるので、 `.into_iter().collect()` して `HashMap` にする

このうち、`key: value` の形を見つける部分がちょっと大変で、`{$key:expr : $($rest:tt)*}` などでマッチしようとするとコンパイラに怒られてしまいます、 `expr` の区切りとして `:` は使えなくて、 `=>` が `,` か `;` だそうです。macro のマッチなどはなかなか仕様が大変そうです。
こんなときにどうするかというと、前から順番に `tt` を一つずつ見て、 `:` が先頭に来るまで取り出していく、といったようなことをします(↑の macros.rs のコード片で言うと、 220 行目あたりです)。一回一回 `object!` macro を繰り返し呼ぶということなので、ちょっとパフォーマンスに懸念がありますね。まあコンパイル時に行われることなのでよいかなという気もします。ちなみに、こんな感じで macro で `tt` を1つ1つ取り出すことを、munch と呼ぶそうです。むしゃむしゃ食べるみたいな意味らしいです。

他にも `array!` macro や `object!` macro では trailing comma の処理が色々試してみてもうまくいかず、結局同じような処理を2回書きがちみたいな感じにもなっているので、ちょっと悔いが残る感じの実装になってます。


# CI について
CIもいくつか作ってるので、これについても書いてみます。

## 単体テスト、formatter のチェック、linterのチェック
https://github.com/hayas1/json-with-comments/blob/v0.1.5/.github/workflows/pullrequest.yml#L28-L32
`cargo test` とか `cargo fmt --check` とか `cargo clippy --tests -- --deny warnings` とかをやっているだけではあります。
自動フォーマットとかは CI ではしておらず、CIがこけるみたいな感じになっています。 CI に勝手にコミットされるのがうれしくないと思ったためです。
ローカルで自動フォーマットされるのでこけたことはないです

## ドキュメント生成
https://github.com/hayas1/json-with-comments/blob/v0.1.5/.github/workflows/master.yml#L31-L36
https://github.com/hayas1/json-with-comments/blob/v0.1.5/.github/workflows/master.yml#L42-L54
`master` ブランチの push (PR の merge も含む) をトリガーに `cargo doc --no-deps` して、 GitHub Pages に上げています。
[actions/upload-pages-artifact](https://github.com/actions/upload-pages-artifact) を使って生成されたdocを artifact に上げ、[actions/deploy-pages](https://github.com/actions/deploy-pages) を使って GitHub Pages に反映するという、最近のスタンダードなやり方をしています。
`cargo doc` とかをしていると .lock みたいなパーミッションが 600 のファイルが生成され、それがあるとうまく GitHub Pages に反映できずこけるため、ファイルを消すなどしないといけないというちょっとした落とし穴があります。
https://github.com/orgs/community/discussions/40771#discussioncomment-8344735

↓のURLにドキュメントをアップロードしています
https://hayas1.github.io/json-with-comments/json_with_comments/

docについては [crates.io](https://crates.io/) に公開すると [docs.rs](https://docs.rs/) に上がるそうなので、そこまで必要ないことかもしれないですね

## カバレッジ計測
test のカバレッジに計測には [cargo-tarpaulin](https://crates.io/crates/cargo-tarpaulin) を使ってます。
`cargo tarpaulin --output-dir target/doc --manifest-path Cargo.toml --out Html` をして doc 配下にカバレッジに関しての HTML が置かれるので、ドキュメントと同様に GitHub Pages に上げています。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/.github/workflows/master.yml#L27-L30

↓のURLにカバレッジについてアップロードされてます。あたらめて見ると 68.75% となかなか低かったですね 😰
https://hayas1.github.io/json-with-comments/tarpaulin-report

## READMEの追従漏れチェック
ドキュメントのために `lib.rs` にクレートの概要や使い方を書くわけですが、これって `README.md` とだいたい同じですよね。というわけで、[cargo-readme](https://github.com/webern/cargo-readme)を使って、[lib.rs](https://github.com/hayas1/json-with-comments/blob/v0.1.5/src/lib.rs) のドキュメントから [README.md](https://github.com/hayas1/json-with-comments/blob/v0.1.5/README.md) を自動生成します。

とはいえ、CIにコミットされるのはあまりうれしくないと思っているので、コミット自体は手動で行うことになります。
そこで、CIでは `cargo readme` を実行して生成される `README.md` に差分が無いかだけを確認しています。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/.github/workflows/pullrequest.yml#L34-L35

`README.md` の更新が漏れていると CI がこけて気づくことができるので、個人的にはよい落としどころだったかなと思っています。

## タグの付与
Rust のプログラムを Git 管理すると、`Cargo.toml` に書いているバージョンと、Git でつけるタグのバージョンで、2つのバージョンを管理することになります。
それらを手動で同期をとるのは大変なので、 `Cargo.toml` に書いてあるバージョンで Git にもタグをつけるようにしたいです。そこで、CI ではそれらの差分を検知する [composite action](https://docs.github.com/ja/actions/creating-actions/creating-a-composite-action) を用意して、柔軟に使えるようにしています。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/.github/actions/versions/action.yml#L24-L46

- PR がトリガーの CI では、マージするとバージョンが上がる場合に `release` のラベルを付与する

https://github.com/hayas1/json-with-comments/blob/v0.1.5/.github/workflows/pullrequest.yml#L37-L52

- master ブランチの CI では、実際にタグを付与する

https://github.com/hayas1/json-with-comments/blob/v0.1.5/.github/workflows/master.yml#L56-L75

こうして、 `Cargo.toml` に書くバージョンだけを管理すればよい状態にすることができました。

## リリースドラフト作成
GitHub でリリースをいい感じに作るとなると、主な選択肢は2つあります。release-drafter と GitHub 公式のリリースノート自動生成機能です。
https://github.com/release-drafter/release-drafter
https://docs.github.com/ja/repositories/releasing-projects-on-github/automatically-generated-release-notes

release-drafter も機能が豊富でいいですが、今回は公式のものを使うことにしました。公式のものについて機能を簡単に説明すると、↓のような `.github/release.yml` を書いておくことで、リリース作成時に 「Generate Release Notes」ボタンを押すと、 PR のタイトルやラベルをもとにリリースノートを自動生成してくれます。
https://github.com/hayas1/json-with-comments/blob/v0.1.5/.github/release.yml#L1-L23

いくつかリリースをしていますが、リリースノートはそうやって作成されています。
https://github.com/hayas1/json-with-comments/releases/tag/v0.1.5

ちなみに、「Generate Release Notes」ボタンを手動で押すために、 master ブランチの CI では、リリースのドラフトだけを作成するようになっています。
「Generate Release Notes」ボタンを押したときに得られる文字列は、GitHub の API を叩くことで手に入れられるようなのですが、そこにはまだ取り組めていないです。 公式の機能なのでリリースドラフトを用意するのに使っている [actions/create-release](https://github.com/actions/create-release) にやってもらいたいところでもあるものの、もうアーカイブされてしまっているようなので望み薄ですね 😥
https://github.com/hayas1/json-with-comments/blob/v0.1.5/.github/workflows/master.yml#L56-L75


# 感想
serdeが提供する抽象化に沿ってコードを書いていけばいい感じのパーサーを作ることができてすごいです。
一方で、記述量はその分なかなか多くなります。自分で工夫できる領域も少なくなるのでちょっと物足りない部分もあります。


