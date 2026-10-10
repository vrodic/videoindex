cmake_minimum_required(VERSION 3.16)
project(VideoIndex VERSION 1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

find_package(Qt6 REQUIRED COMPONENTS Widgets Sql)
find_package(PkgConfig REQUIRED)
pkg_check_modules(SQLITE3 REQUIRED sqlite3)

set(SOURCES
    src/main.cpp
    src/MediaItem.cpp
    src/Database.cpp
    src/ThumbnailManager.cpp
    src/ShortcutTableView.cpp
    src/CustomItemDelegate.cpp
    src/ClickableThumbnailLabel.cpp
    src/WordCloudDialog.cpp
    src/MainWindow.cpp
)

set(HEADERS
    src/MediaItem.h
    src/Database.h
    src/ThumbnailManager.h
    src/ShortcutTableView.h
    src/CustomItemDelegate.h
    src/ClickableThumbnailLabel.h
    src/WordCloudDialog.h
    src/MainWindow.h
)

add_executable(VideoIndex ${SOURCES} ${HEADERS})

target_include_directories(VideoIndex PRIVATE ${SQLITE3_INCLUDE_DIRS} src)
target_link_libraries(VideoIndex PRIVATE Qt6::Widgets Qt6::Sql ${SQLITE3_LIBRARIES})
