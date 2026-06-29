package app.droidmatch.m1;

public final class DmFileProvider {
    public String[] listRoots() {
        return new String[] {
                "dm://media-images/",
                "dm://media-videos/",
                "dm://saf-primary/"
        };
    }
}
