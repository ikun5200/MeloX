import Foundation

nonisolated enum QQMusicMapper {
    static func searchPayload(_ result: QQSearchResult) -> SearchPayload {
        SearchPayload(
            songs: result.songs.isEmpty
                ? nil
                : result.songs.map { song($0) },
            albums: result.albums.isEmpty
                ? nil
                : result.albums.map { album($0) },
            artists: result.artists.isEmpty
                ? nil
                : result.artists.map { artist($0) },
            playlists: result.playlists.isEmpty
                ? nil
                : result.playlists.map { playlist($0) },
            podcasts: nil
        )
    }

    static func song(_ value: QQSearchSong) -> Song {
        Song(
            id: value.id,
            name: value.name,
            artists: value.artists.map(artist),
            album: Album(
                id: value.albumID,
                mid: value.albumMID,
                name: value.albumName,
                picURL: value.coverURL,
                artists: value.artists.map(artist)
            ),
            durationMS: max(value.durationSeconds, 0) * 1_000,
            musicVideoID: value.musicVideoID,
            audioAvailability: value.audioAvailability,
            mid: value.mid,
            mediaMID: value.mediaMID,
            musicVideoMID: value.musicVideoMID
        )
    }

    static func artist(_ value: QQSearchArtist) -> Artist {
        Artist(
            id: value.id,
            mid: value.mid,
            name: value.name,
            avatarURL: value.avatarURL,
            isFollowed: value.isFollowed
        )
    }

    static func album(_ value: QQSearchAlbum) -> Album {
        Album(
            id: value.id,
            mid: value.mid,
            name: value.name,
            picURL: value.coverURL,
            artists: value.artists.map(artist)
        )
    }

    static func playlist(
        _ value: QQSearchPlaylist,
        creatorID: Int = 0,
        subscribed: Bool = false
    ) -> Playlist {
        Playlist(
            id: value.id,
            name: value.name,
            coverURLString: value.coverURL,
            trackCount: value.trackCount,
            playCount: value.playCount,
            creator: UserSummary(
                userID: creatorID,
                nickname: value.creatorName ?? ""
            ),
            subscribed: subscribed,
            dirid: value.dirid
        )
    }

    static func playlist(_ value: QQPlaylistDetail) -> Playlist {
        let songs = value.songs.map(song)
        return Playlist(
            id: value.id,
            name: value.name,
            coverURLString: value.coverURL,
            playlistDescription: value.description,
            trackCount: value.trackCount,
            playCount: value.playCount,
            creator: UserSummary(
                userID: value.creatorID,
                nickname: value.creatorName ?? ""
            ),
            tracks: songs,
            trackIDs: songs.map { TrackReference(id: $0.id) },
            dirid: value.dirid
        )
    }

    static func albumDetail(
        _ value: QQAlbumDetail
    ) -> (Album, [Song]) {
        let mapped = album(value.album)
        let detailedAlbum = Album(
            id: mapped.id,
            mid: mapped.mid,
            name: mapped.name,
            picURL: mapped.picURL,
            artists: mapped.artists,
            albumDescription: value.description
        )
        return (detailedAlbum, value.songs.map(song))
    }

    static func artistDetail(
        _ value: QQArtistDetail
    ) -> (Artist, [Song], [Album], String?) {
        (
            artist(value.artist),
            value.songs.map(song),
            value.albums.map(album),
            value.description
        )
    }

    static func comment(_ value: QQComment) -> SongComment {
        SongComment(
            id: value.id,
            user: SongCommentUser(
                id: QQMusicSearchParser.stableID(String(value.id)),
                nickname: value.nickname,
                avatarURLString: value.avatarURL
            ),
            content: value.content,
            time: Double(value.publishedAt) * 1_000,
            timeDescription: nil,
            likedCount: value.likedCount,
            isLiked: value.isLiked,
            replies: [],
            ipLocation: nil,
            floorSummary: nil
        )
    }

    static func toplistDetail(_ value: QQPlaylistDetail) -> Playlist {
        let songs = value.songs.map(song)
        return Playlist(
            id: value.id,
            name: value.name,
            coverURLString: value.coverURL,
            playlistDescription: value.description,
            trackCount: value.trackCount,
            playCount: value.playCount,
            toplistType: "qq",
            tracks: songs,
            trackIDs: songs.map { TrackReference(id: $0.id) }
        )
    }

    static func toplist(_ value: QQToplist) -> Playlist {
        Playlist(
            id: value.id,
            name: value.name,
            coverURLString: value.coverURL,
            playlistDescription: value.description,
            trackCount: value.trackCount,
            playCount: value.playCount,
            toplistType: "qq"
        )
    }
}
