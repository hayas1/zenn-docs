---
title: "Rust: Vec<T>のindexはTだけでなく[T]も返している"
emoji: "🥬"
type: "tech"
topics: ["rust"]
published: true
---

# 返り値の型
Rustで関数を書いていると、返り値の型はだいたい1つになると思います。
しかし `Vec<T>` にインデックスアクセスすると、シンプルに `usize` でアクセスしたときは `T` を返すのに、 `Range` でアクセスしたときは `[T]` を返しています。
つまり引数の型によって返り値の型も変わっていて、これを疑問に思ったことがあったので、その裏側について書いていきます。

```rust
fn main() {
    let v = vec![1, 2, 3];
    assert_eq!(v[0], 1); // T
    assert_eq!(v[1..3], [2, 3]); // [T]
}
```
なお、結論から書くと `index` 関連の処理は [`SliceIndex`](https://doc.rust-lang.org/std/slice/trait.SliceIndex.html) トレイトに集約されており、その Associated Type である `Output` をうまく使って実現されています。つまり `Vec` やスライスのインデックスアクセスの処理は、 `Vec` やスライスに直接実装されているのではなく `usize` や `Range` の側に `SliceIndex` トレイトとして実装されているという形です。

# `Vec::index` の中身を見ていく
そもそも `Vec<T>` のインデックスアクセスは `Vec` が `Index` トレイトを実装しているため実現されています。
つまり、そのあたりにヒントがあるはずなので、[ドキュメント](https://doc.rust-lang.org/std/vec/struct.Vec.html#impl-Index%3CI%3E-for-Vec%3CT,+A%3E)を漁って[ソース](https://github.com/rust-lang/rust/blob/1.77.1/library/alloc/src/vec/mod.rs#L2766-L2773)など見てみると、 `Vec<T>` の `index` の実装は ` Index::index(&**self, index)` となっており、つまりスライス `[T]` の `index` に処理を任せていそうな様子なので、 `<[T]>::index` について見てみます。

`<[T]>::index` の実装は、以下のようになっていて、(だいたい `Vec::index` とも同じですが、)いくつか見えてくることがあります。
https://github.com/rust-lang/rust/blob/1.77.1/library/core/src/slice/index.rs#L10-L20

- インデックスアクセスの引数には `SliceIndex` トレイトを受け取っている( `usize` や `Range` を直接受け取っていない)
- インデックスアクセスの返り値は `SliceIndex::Output` になっている
- インデックスアクセスの実装も `SliceIndex` トレイトの `index` メソッドに任されている

つまり、 [`SliceIndex`](https://doc.rust-lang.org/std/slice/trait.SliceIndex.html) トレイトについて深堀っていくとよさそうです。

# `SliceIndex` トレイトは何者か
[`SliceIndex`](https://doc.rust-lang.org/std/slice/trait.SliceIndex.html) トレイトのドキュメントを見ると `get` や `index` といったメソッドが要求されています。
```rust
pub unsafe trait SliceIndex<T>: Sealed
where
    T: ?Sized,
{
    type Output: ?Sized;

    // Required methods
    fn get(self, slice: &T) -> Option<&Self::Output>;
    fn get_mut(self, slice: &mut T) -> Option<&mut Self::Output>;
    unsafe fn get_unchecked(self, slice: *const T) -> *const Self::Output;
    unsafe fn get_unchecked_mut(self, slice: *mut T) -> *mut Self::Output;
    fn index(self, slice: &T) -> &Self::Output;
    fn index_mut(self, slice: &mut T) -> &mut Self::Output;
}
```

ここで `get` が出てきましたが、`Vec` にも [`get` メソッド](https://doc.rust-lang.org/std/vec/struct.Vec.html#method.get)があり、これも引数に `SliceIndex` トレイトを受け取っているようです。たしかに `get` メソッドも `Option<T>` を返したり `Option<[T]>` を返したりしますね。

さて [`SliceIndex`](https://doc.rust-lang.org/std/slice/trait.SliceIndex.html) トレイトのドキュメントの[下の方](https://doc.rust-lang.org/std/slice/trait.SliceIndex.html#implementors)を見ると、誰がこのトレイトを実装しているかが載っています。`SliceIndex<[T]>` を実装しているのは、以下の8つのようです。
- `(Bound<usize>, Bound<usize>)`
- `usize`
- `Range<usize>`
- `RangeTo<usize>`
- `RangeFrom<usize>`
- `RangeFull`
- `RangeInclusive<usize>`
- `RangeToInclusive<usize>`

つまるところ、 `usize` や `Range` の各種 struct あたりのようです。補足すると、Rustで range を表現する時、`0..10` や `..=10` など、いろいろ柔軟な表現ができますが、その正体が `Range` や `RangeToInclusive` などの struct です。このあたりについては以前 [`RangeBounds`](https://doc.rust-lang.org/std/ops/trait.RangeBounds.html) トレイトについて書いた記事があるので、そちらへのリンク載せておきます。(`SliceIndex`トレイトを`Range`の各種 struct に実装しなくても `RangeBounds` トレイトでまとめて実装できそうにも見えますが、trait実装の衝突を嫌ったのでしょうか)
https://qiita.com/hystcs/items/8e064f8b9a79adb9cca7

# `usize` と `Range` の `SliceIndex` トレイト実装
この記事で知りたかった `[T]` に `usize` でインデックスアクセスしたときと `Range` でインデックスアクセスしたときの返り値の型の違いがどのように実現されているかにだいぶ近づいてきました。

`usize` の `SliceIndex<[T]>` 実装では、Associated Type `Output = T` です。
https://github.com/rust-lang/rust/blob/1.77.1/library/core/src/slice/index.rs#L211-L263

一方で、 `Range<usize>` の `SliceIndex<[T]>` 実装では、Associated Type `Output = [T]` になっています。
https://github.com/rust-lang/rust/blob/1.77.1/library/core/src/slice/index.rs#L337-L410

はじめの方で見ていたように、スライス `[T]` のインデックスアクセスの返り値は `SliceIndex::Output` になっていました。つまり、上記の `usize` や `Range` などの `SliceIndex` の実装における Associated Type `Output` がそのままインデックスアクセスの返り値の型になっているということですね。


# まとめ
`Vec<T>` や `[T]` に `usize` でインデックスアクセスすると `T` が返り、`Range` でインデックスアクセスすると `[T]` が返る仕組みがどのように実現されているかを知ることができました。
`Vec` や `slice` にインデックスアクセスする処理が、 `Vec` や `slice` に対して直接実装されているわけではなく、 `SliceIndex` トレイトを通して `usize` や各種 `Range` の方に実装されているところもとても面白いと思います。
こういった依存性を逆転させるようなデザインパターンはしばしば出現してなかなか有用なので、やはり標準ライブラリの実装には学びが多いです。
