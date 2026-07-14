package app.droidmatch.m1;

import android.database.Cursor;

import java.lang.reflect.Proxy;

/** Deterministic host-JVM Cursor interface fixture; it owns no Android storage state. */
final class CursorTestFixture {
    private CursorTestFixture() {}

    static Cursor cursor(String[] columns, Object[][] rows) {
        int[] position = new int[] { -1 };
        return (Cursor) Proxy.newProxyInstance(
                Cursor.class.getClassLoader(),
                new Class<?>[] { Cursor.class },
                (proxy, method, arguments) -> {
                    String name = method.getName();
                    if ("getColumnIndexOrThrow".equals(name) || "getColumnIndex".equals(name)) {
                        String column = (String) arguments[0];
                        for (int index = 0; index < columns.length; index++) {
                            if (columns[index].equals(column)) {
                                return index;
                            }
                        }
                        if ("getColumnIndex".equals(name)) {
                            return -1;
                        }
                        throw new IllegalArgumentException("missing column");
                    }
                    if ("moveToNext".equals(name)) {
                        if (position[0] + 1 < rows.length) {
                            position[0]++;
                            return true;
                        }
                        position[0] = rows.length;
                        return false;
                    }
                    if ("moveToFirst".equals(name)) {
                        position[0] = rows.length == 0 ? -1 : 0;
                        return rows.length != 0;
                    }
                    if ("isNull".equals(name)) {
                        return value(rows, position[0], (Integer) arguments[0]) == null;
                    }
                    if ("getString".equals(name)) {
                        Object value = value(rows, position[0], (Integer) arguments[0]);
                        return value == null ? null : value.toString();
                    }
                    if ("getInt".equals(name)) {
                        return ((Number) value(rows, position[0], (Integer) arguments[0])).intValue();
                    }
                    if ("getLong".equals(name)) {
                        return ((Number) value(rows, position[0], (Integer) arguments[0])).longValue();
                    }
                    if ("getCount".equals(name)) {
                        return rows.length;
                    }
                    if ("getPosition".equals(name)) {
                        return position[0];
                    }
                    if ("getColumnNames".equals(name)) {
                        return columns.clone();
                    }
                    if ("close".equals(name)) {
                        return null;
                    }
                    Class<?> type = method.getReturnType();
                    if (type == boolean.class) {
                        return false;
                    }
                    if (type == int.class) {
                        return 0;
                    }
                    if (type == long.class) {
                        return 0L;
                    }
                    if (type == float.class) {
                        return 0F;
                    }
                    if (type == double.class) {
                        return 0D;
                    }
                    return null;
                }
        );
    }

    private static Object value(Object[][] rows, int row, int column) {
        if (row < 0 || row >= rows.length) {
            throw new IllegalStateException("cursor is not positioned on a row");
        }
        return rows[row][column];
    }
}
