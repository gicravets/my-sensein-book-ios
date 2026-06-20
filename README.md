# my-sensein-book-ios

iOS-приложение **My.Sensein.Book** — читалка EPUB/FB2 на SwiftUI с собственным движком (без сторонних зависимостей). Часть проекта **my-sensein-book**.

- **Продукт:** My.Sensein.Book
- **Имя на иконке:** book
- **Разработчик:** Kravitz Geroge
- **Bundle ID:** `com.sensein.book`

## Запуск

```bash
xcodegen generate              # сгенерировать my-sensein-book.xcodeproj
open my-sensein-book.xcodeproj # открыть в Xcode и нажать Run (⌘R)
```

Требуется Xcode 16+ и [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
Цель сборки — iOS 16+. При первом запуске в библиотеку импортируется пример книги
(`Resources/Sample.epub`, Pride and Prejudice, public domain).

Сборка из командной строки:

```bash
xcodebuild -project my-sensein-book.xcodeproj -scheme my-sensein-book \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
```

## Что умеет

- Библиотека: импорт EPUB/FB2, обложки, прогресс, полки, выбор/сортировка/поиск, признак «прочитано».
- Читалка: постраничная вёрстка (WKWebView, собственная пагинация), темы, размер шрифта.
- Закладки и выделения с заметками (reflow-safe локаторы).

## Структура

```
Sources/
  App/            # точка входа (MySenseinBookApp), RootTabView
  Models/         # Book, Bookmark, Highlight, LibraryStore, …
  ...
Resources/        # Sample.epub и ассеты
project.yml       # спецификация XcodeGen (источник истины для .xcodeproj)
```

## Связанные репозитории

- Бэкенд: [my-sensein-book-backend](https://github.com/gicravets/my-sensein-book-backend)
- Веб-PWA: [my-sensein-book-frontend](https://github.com/gicravets/my-sensein-book-frontend)
